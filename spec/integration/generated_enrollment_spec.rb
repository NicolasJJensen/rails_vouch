# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "generators/vouch/two_factorable/two_factorable_generator"
require "generators/vouch/eject/eject_generator"

RSpec.describe "generated MFA enrollment" do
  before do
      directory = @directory = Dir.mktmpdir("vouch-enrollment")
      FileUtils.mkdir_p("#{directory}/app/models")
      File.write("#{directory}/app/models/two_factor_credential.rb", <<~RUBY)
        class TwoFactorCredential < ApplicationRecord
          belongs_to :account
        end
      RUBY
      generator = Vouch::Generators::TwoFactorableGenerator.new(["TwoFactorCredential"],
        subject: ["otp_secret"], auth_scope: "user", controller_path: "generated_enrollments")
      generator.destination_root = directory
      generator.invoke_all
      stub_const("GeneratedEnrollments", Module.new)
      load "#{directory}/app/controllers/generated_enrollments/two_factor_credentials_controller.rb"
  end

  after { FileUtils.rm_rf(@directory) if @directory }

  it "renders the generated enrollment form only after the complete host action returns" do
    observations = []
    GeneratedEnrollments::TwoFactorCredentialsController.prepend(Module.new do
      define_method(:create) do
        status = super()
        observations << [status, performed?, @credential.persisted?]
      end
    end)

    _controller, response = dispatch_enrollment(:create, params: {
      two_factor_credential: { otp_secret: "new-secret" }
    })

    expect(observations).to eq([[:ok, false, true]])
    expect(response.status).to eq(202)
    expect(response.body).to include("Verify and enable", "Verification code")
  end

  it "preserves a host JSON response after generated enrollment sends its verification code" do
    GeneratedEnrollments::TwoFactorCredentialsController.prepend(Module.new do
      def create
        status = super
        render json: { status: status, id: @credential.id, awaiting_verification: @awaiting_verification }, status: :created
      end
    end)

    controller, response = dispatch_enrollment(:create, params: {
      two_factor_credential: { otp_secret: "new-secret" }
    })

    expect(response.status).to eq(201)
    expect(JSON.parse(response.body)).to eq("status" => "ok", "id" => controller.instance_variable_get(:@credential).id,
      "awaiting_verification" => true)
    expect(controller.session).not_to be_empty
  end

  it "prepares the new credential but does not save or deliver after host authorization denies enrollment" do
    GeneratedEnrollments::TwoFactorCredentialsController.prepend(Module.new do
      def create
        raise "Credential was not prepared" unless @credential&.new_record?
        head :forbidden
        super
      end
    end)
    expect_any_instance_of(TwoFactorCredential).not_to receive(:start_verification)

    expect do
      _controller, response = dispatch_enrollment(:create, params: {
        two_factor_credential: { otp_secret: "new-secret" }
      })
      expect(response.status).to eq(403)
    end.not_to change(TwoFactorCredential, :count)
  end

  it "preserves enrollment and inherited management fallbacks after ejection" do
    generator = Vouch::Generators::EjectGenerator.new(["generated_enrollments", "two_factor_credentials"], auth_scope: "user")
    generator.destination_root = @directory
    generator.invoke_all
    GeneratedEnrollments.send(:remove_const, :TwoFactorCredentialsController)
    load File.join(@directory, "app/controllers/generated_enrollments/two_factor_credentials_implementation_controller.rb")
    load File.join(@directory, "app/controllers/generated_enrollments/two_factor_credentials_controller.rb")
    observed = []
    GeneratedEnrollments::TwoFactorCredentialsController.prepend(Module.new do
      %i[create destroy].each do |action|
        define_method(action) do
          status = super()
          observed << [action, status, performed?]
        end
      end
    end)

    controller, response = dispatch_enrollment(:create, params: {
      two_factor_credential: { otp_secret: "new-secret" }
    })
    expect(response.status).to eq(202)
    credential = controller.instance_variable_get(:@credential)
    expect(response.body).to include("Verify and enable")

    expect do
      _controller, response = dispatch_enrollment(:destroy, account: credential.account, params: { id: credential.id })
      expect(response.status).to eq(302)
      expect(response.location).to end_with("/users/two_factor_credentials")
    end.to change(TwoFactorCredential, :count).by(-1)
    expect(observed).to eq([[:create, :ok, false], [:destroy, :ok, false]])
  end

  it "enrolls through persisted verification, allows retry, and scopes lookup to the owner" do
    account = create(:account)
    controller = GeneratedEnrollments::TwoFactorCredentialsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    session = {}
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_verification_code) { |_record, code| delivered = code }
    allow(controller).to receive(:current_account).and_return(account)
    allow(controller).to receive(:session).and_return(session)
    allow(controller).to receive(:performed?).and_return(false)
    allow(controller).to receive(:render)
    allow(controller).to receive(:redirect_to)

    allow(controller).to receive(:action_name).and_return("new")
    controller.send(:build_credential)
    controller.new
    expect(controller.instance_variable_get(:@credential).account).to eq(account)
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
      two_factor_credential: {otp_secret: "enrolled-secret"}))
    allow(controller).to receive(:action_name).and_return("create")
    controller.send(:build_credential)
    expect(controller.create).to eq(:ok)
    credential = controller.instance_variable_get(:@credential)
    expect(credential).to be_persisted
    expect(delivered).to be_present
    expect(session.values).to all(be_a(String))
    expect(controller).not_to have_received(:render)
    controller.send(:default_render)
    expect(controller).to have_received(:render).with(:new, status: :accepted)

    allow(controller).to receive(:action_name).and_return("update")
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: credential.id, code: "incorrect"))
    controller.send(:set_credential)
    expect(controller.update).to eq(:invalid)
    controller.send(:default_render)
    expect(session).not_to be_empty
    expect(credential.reload).not_to be_verified

    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: credential.id, code: delivered))
    cancelled_enable = proc { throw :abort if will_save_change_to_two_factor_enabled? }
    Account.before_update(cancelled_enable)
    controller.send(:set_credential)
    expect(controller.update).to eq(:cancelled)
    expect(credential.reload).not_to be_verified
    expect(credential).not_to be_two_factor_enabled
    expect(account.reload).not_to be_two_factor_enabled
    expect(session).not_to be_empty
    Account.skip_callback(:update, :before, cancelled_enable)
    cancelled_enable = nil

    controller.send(:set_credential)
    expect(controller.update).to eq(:ok)
    expect(credential.reload).to be_verified
    expect(credential).to be_two_factor_enabled
    expect(account.reload).to be_two_factor_enabled
    expect(session).to be_empty
    expect(controller).not_to have_received(:redirect_to)
    controller.send(:default_render)
    expect(controller).to have_received(:redirect_to).with("/users/two_factor_credentials", notice: "Two-factor credential enabled")

    verified = account.two_factor_credentials.create!(otp_secret: "already-verified", verified_at: Time.current)
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: verified.id))
    controller.send(:set_credential)
    controller.update
    expect(verified.reload).to be_two_factor_enabled

    foreign = create(:account).two_factor_credentials.create!
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: foreign.id, code: delivered))
    expect(controller).to receive(:head).with(:not_found)
    controller.send(:set_credential)
  ensure
    Account.skip_callback(:update, :before, cancelled_enable) if cancelled_enable
  end

  def dispatch_enrollment(action, params:, account: create(:account))
    identity = create(:user, account: account)
    controller = GeneratedEnrollments::TwoFactorCredentialsController.new
    controller.class.prepend_view_path(File.join(@directory, "app/views"))
    allow(controller).to receive(:current_account).and_return(account)
    allow(controller).to receive(:current_identity).and_return(identity)
    allow(controller).to receive(:session).and_return({})

    request = ActionDispatch::TestRequest.create
    request.set_header("REQUEST_METHOD", action == :destroy ? "DELETE" : "POST")
    request.set_header("action_dispatch.request.parameters", params.stringify_keys)
    request.set_header("action_dispatch.request.path_parameters", {
      controller: "generated_enrollments/two_factor_credentials", action: action.to_s
    })
    response = ActionDispatch::TestResponse.new
    controller.dispatch(action.to_s, request, response)
    [controller, response]
  end
end
