require "rails_helper"

RSpec.describe Vouch::VerificationsController, type: :controller do
  controller(Vouch::VerificationsController) do
    before_action :set_verifiable

    def create
      head :forbidden if params[:deny] == "yes"
      status = super
      if status == :ok && params[:custom_response] == "yes"
        render json: { record_id: @verifiable.id, delivery: "sent" }, status: :accepted
      end
    end

    private

    def set_verifiable
      @verifiable = PhoneVerification.where(e164: "+61411112222").find(params[:record_id])
    end
  end

  before do
    routes.draw do
      post "verification/:kind/:record_id", to: "vouch/verifications#create"
      patch "verification/:kind/:record_id", to: "vouch/verifications#update"
    end
    allow_any_instance_of(PhoneVerification).to receive(:deliver_verification_code) { |_record, code| @code = code }
  end

  let(:record) { PhoneVerification.create!(e164: "+61411112222") }
  let(:input) { { kind: "phone", record_id: record.id } }

  it "keeps the code challenge in session and verifies the authorized saved record" do
    post :create, params: input
    expect(response.parsed_body["status"]).to eq("ok")
    patch :update, params: input.merge(code: @code)

    expect(response.parsed_body["status"]).to eq("ok")
    expect(record.reload).to be_verified
    expect(session[:vouch_verification_tokens]).to be_empty
  end

  it "does not deliver after the host has handled an authorization failure" do
    post :create, params: input.merge(deny: "yes")

    expect(response).to have_http_status(:forbidden)
    expect(@code).to be_nil
    expect(record.reload.verification_nonce).to be_nil
  end

  it "returns status and exposes the record without requiring an authentication mapping" do
    expect(controller).not_to receive(:auth_mapping)

    post :create, params: input.merge(custom_response: "yes")

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq("record_id" => record.id, "delivery" => "sent")
    expect(session[:vouch_verification_tokens]).to be_present
  end

  it "does not turn an arbitrary record id into authorization" do
    other = PhoneVerification.create!(e164: "+61499999999")

    expect { post :create, params: input.merge(record_id: other.id) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(other.reload.verification_nonce).to be_nil
  end
end
