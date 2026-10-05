require "rails_helper"

RSpec.describe Vouch::TemporaryVerificationsController, type: :controller do
  controller(Vouch::TemporaryVerificationsController) do
    before_action :build_verifiable, only: :create
    before_action :set_verifiable, only: [:update, :destroy]
    before_action :set_existing_verifiable, only: [:create, :update]

    def update
      status = super
      if status == :ok && params[:attach] == "fail"
        render json: { attachment: "failed", verified: @verifiable.verified? }, status: :unprocessable_entity
      elsif status == :ok && params[:attach] == "yes"
        @verifiable.save!
        forget_temporary_verification
        render json: { id: @verifiable.id }, status: :created
      end
    end

    private

    def build_verifiable
      raise ActionController::RoutingError, "Not found" unless params[:kind] == "phone"
      @verifiable = PhoneVerification.new(params.require(:phone).permit(:e164))
    end

    def set_verifiable
      build_verifiable
      @verifiable = restore_temporary_verification(@verifiable)
    end

    def set_existing_verifiable
      @existing_verifiable = PhoneVerification.find_by(e164: @verifiable.e164)
    end
  end

  before do
    routes.draw do
      post "verification/:kind", to: "vouch/temporary_verifications#create"
      patch "verification/:kind", to: "vouch/temporary_verifications#update"
      delete "verification/:kind", to: "vouch/temporary_verifications#destroy"
    end
    allow_any_instance_of(PhoneVerification).to receive(:deliver_verification_code) { |_record, code| @code = code }
  end

  let(:input) { { kind: "phone", phone: { e164: "+61400001111" } } }

  it "issues and verifies without saving a business record, retaining proof until explicitly discarded" do
    expect { post :create, params: input }.not_to change(PhoneVerification, :count)
    expect(response).to have_http_status(:ok)
    patch :update, params: input.merge(code: @code)
    expect(response.parsed_body["status"]).to eq("ok")
    expect(session[:vouch_temporary_verifications]["phone"]).to be_present

    delete :destroy, params: input
    expect(session[:vouch_temporary_verifications]["phone"]).to be_empty
  end

  it "retains verified temporary state when the host cannot attach it" do
    post :create, params: input
    patch :update, params: input.merge(code: @code, attach: "fail")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq("attachment" => "failed", "verified" => true)
    state = session[:vouch_temporary_verifications]["phone"].values.first
    restored = PhoneVerification.new
    restored.restore_verification_state!(state)
    expect(restored).to be_verified
  end

  it "allows the host to attach and discard verified state before choosing the response" do
    post :create, params: input

    expect do
      patch :update, params: input.merge(code: @code, attach: "yes")
    end.to change(PhoneVerification, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(PhoneVerification.find(response.parsed_body.fetch("id"))).to be_verified
    expect(session[:vouch_temporary_verifications]["phone"]).to be_empty
  end

  it "retains attempts and locks after repeated wrong codes" do
    post :create, params: input
    Vouch.configuration.verifiable.max_attempts.times { patch :update, params: input.merge(code: "bad") }
    patch :update, params: input.merge(code: @code)

    expect(response).to have_http_status(:too_many_requests)
  end

  it "rejects old session proof as fresh verification after the subject has been saved and verified" do
    post :create, params: input
    saved = PhoneVerification.create!(e164: input[:phone][:e164], verified_at: Time.current)
    patch :update, params: input.merge(code: @code)

    expect(response.parsed_body["status"]).to eq("already_verified")
    expect(saved.reload).to be_verified
  end

  it "does not accept proof attributes or changed business fields on completion" do
    post :create, params: input
    patch :update, params: input.merge(code: "bad", phone: input[:phone].merge(verified_at: Time.current))

    expect(response.parsed_body["status"]).to eq("invalid")
  end
end

RSpec.describe "Temporary verification native rate limits", type: :controller do
  before { @original_action_callbacks = controller.class._process_action_callbacks }
  after { controller.class._process_action_callbacks = @original_action_callbacks }

  controller(Vouch::TemporaryVerificationsController) do
    RATE_STORE = Vouch::VerificationRateLimitStore.new(Class.new do
      def initialize
        @counts = {}
        @mutex = Mutex.new
      end

      def increment(key, amount, expires_in:)
        @mutex.synchronize do
          value, expires_at = @counts[key]
          value, expires_at = 0, Time.current + expires_in if !expires_at || expires_at <= Time.current
          @counts[key] = [value + amount, expires_at]
          value + amount
        end
      end
    end.new)

    rate_limit to: 20, within: 10.minutes, only: :create,
      name: "delivery-ip", scope: "verification", store: RATE_STORE
    before_action :build_verifiable, only: :create
    rate_limit to: 3, within: 10.minutes, only: :create,
      by: :verification_subject_key, name: "delivery-subject", scope: "verification", store: RATE_STORE

    private

    def build_verifiable
      @verifiable = PhoneVerification.new(e164: params.require(:phone).fetch(:e164))
      @existing_verifiable = nil
    end
  end

  before do
    routes.draw { post "verification/:kind", to: "vouch/temporary_verifications#create" }
  end

  it "shares the subject budget across fresh sessions and kind aliases" do
    3.times do |index|
      session.clear
      post :create, params: { kind: index.even? ? "phone" : "mobile", phone: { e164: "+61499887766" } }
      expect(response).to have_http_status(:ok)
    end
    session.clear
    expect do
      post :create, params: { kind: "another_alias", phone: { e164: "+61499887766" } }
    end.to raise_error(ActionController::TooManyRequests)
  end
  it "allows the boundary count and starts a new window after expiry" do
    input = { kind: "phone", phone: { e164: "+61499887711" } }
    3.times { post :create, params: input }
    expect(response).to have_http_status(:ok)
    expect { post :create, params: input }.to raise_error(ActionController::TooManyRequests)

    travel(10.minutes + 1.second) { post :create, params: input }
    expect(response).to have_http_status(:ok)
  end

  it "supports the host's native custom throttled response" do
    controller.class.rate_limit to: 0, within: 10.minutes, only: :create,
      name: "custom-response", scope: "verification", store: RATE_STORE,
      with: -> { render json: { retry: "later" }, status: :too_many_requests }

    post :create, params: { kind: "phone", phone: { e164: "+61499887722" } }

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to eq("retry" => "later")
  end

  it "returns 503 without sending when the shared counter is unavailable" do
    unavailable = double("unavailable cache", increment: nil)
    controller.class.rate_limit to: 20, within: 10.minutes, only: :create,
      name: "availability", scope: "verification", store: Vouch::VerificationRateLimitStore.new(unavailable)

    post :create, params: { kind: "phone", phone: { e164: "+61499887700" } }

    expect(response).to have_http_status(:service_unavailable)
    expect(session[:vouch_temporary_verifications]).to be_nil
  end

end
