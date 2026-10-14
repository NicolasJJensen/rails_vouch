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

  it "requires subject attributes before presenting an enrollment form" do
    allow(TwoFactorCredential).to receive(:verifiable_subject_attribute).and_return(nil)

    expect { dispatch_enrollment(:new, params: {}) }
      .to raise_error(ActionView::Template::Error, /Set verifiable_subject_attribute on TwoFactorCredential/)
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

  it "resumes enrollment without sending a code and replaces an expired code on request" do
    account = create(:account)
    session = {}
    codes = []
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_verification_code) { |_record, code| codes << code }
    controller, response = dispatch_enrollment(:create, account: account, session: session,
      params: {two_factor_credential: {otp_secret: "pending-secret"}})
    credential = controller.instance_variable_get(:@credential)
    old_token = session.values.first
    expect(response.status).to eq(202)

    _, index = dispatch_enrollment(:index, account: account, session: session, params: {})
    expect(index.body).to include("Continue verification", "/users/two_factor_credentials/#{credential.id}/edit")
    _, edit = dispatch_enrollment(:edit, account: account, session: session, params: {id: credential.id})
    expect(edit.status).to eq(200)
    expect(edit.body).to include("Verify and enable", "Resend verification code")
    expect(codes.size).to eq(1)
    expect(session.values).to eq([old_token])

    travel 1.day
    _, resent = dispatch_enrollment(:send_code, account: account, session: session, params: {id: credential.id})
    expect(resent.status).to eq(202)
    expect(codes.size).to eq(2)
    expect(session.values).not_to include(old_token)
    expect(credential.reload.complete_verification(codes.first, token: old_token)).to be_invalid

    _, completed = dispatch_enrollment(:update, account: account, session: session,
      params: {id: credential.id, code: codes.last})
    expect(completed.status).to eq(302)
    expect(credential.reload).to be_verified
    expect(credential).to be_two_factor_enabled
    expect(account.reload).to be_two_factor_enabled
    expect(session).to be_empty
  end

  it "invalidates a still-current code on resend and supports a fresh browser session" do
    account = create(:account)
    credential = account.two_factor_credentials.create!(otp_secret: "resend-secret")
    code = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_verification_code) { |_record, sent| code = sent }
    old_token = credential.start_verification.token
    old_code = code
    session = {}

    _, response = dispatch_enrollment(:send_code, account: account, session: session, params: {id: credential.id})

    expect(response.status).to eq(202)
    expect(credential.reload.complete_verification(old_code, token: old_token)).to be_invalid
    expect(credential.complete_verification(code, token: session.values.first)).to be_ok
  end

  it "limits delivery across initial enrollment and resends for the same owner" do
    account = create(:account)
    controller, = dispatch_enrollment(:create, account: account,
      params: {two_factor_credential: {otp_secret: "limited-secret"}})
    credential = controller.instance_variable_get(:@credential)
    4.times do
      _, response = dispatch_enrollment(:send_code, account: account, params: {id: credential.id})
      expect(response.status).to eq(202)
    end
    nonce = credential.reload.verification_nonce

    expect_any_instance_of(TwoFactorCredential).not_to receive(:deliver_verification_code)
    expect {
      dispatch_enrollment(:send_code, account: account, params: {id: credential.id})
    }.to raise_error(ActionController::TooManyRequests)
    expect(credential.reload.verification_nonce).to eq(nonce)
  end

  it "does not expose or resend another owner's pending enrollment" do
    credential = create(:account).two_factor_credentials.create!(otp_secret: "other-owner")
    expect_any_instance_of(TwoFactorCredential).not_to receive(:start_verification)

    %i[edit send_code].each do |action|
      _, response = dispatch_enrollment(action, params: {id: credential.id})
      expect(response.status).to eq(404)
    end
  end

  it "does not resend codes for verified or locked credentials" do
    account = create(:account)
    verified = account.two_factor_credentials.create!(otp_secret: "verified", verified_at: Time.current)
    locked = account.two_factor_credentials.create!(otp_secret: "locked", verification_locked_at: Time.current)
    expect_any_instance_of(TwoFactorCredential).not_to receive(:deliver_verification_code)

    _, edit = dispatch_enrollment(:edit, account: account, params: {id: verified.id})
    expect(edit.status).to eq(302)
    controller, resent = dispatch_enrollment(:send_code, account: account, params: {id: verified.id})
    expect(resent.status).to eq(302)
    expect(controller.instance_variable_get(:@operation_status)).to eq(:already_verified)
    controller, rejected = dispatch_enrollment(:send_code, account: account, params: {id: locked.id})
    expect(rejected.status).to eq(422)
    expect(controller.instance_variable_get(:@operation_status)).to eq(:locked)
    expect(rejected.body).to include("A verification code could not be sent")
  end

  it "lets the host deny or replace the resend response after preparing the credential" do
    GeneratedEnrollments::TwoFactorCredentialsController.prepend(Module.new do
      def send_code
        return head :forbidden if @credential.otp_secret == "denied"

        status = super
        render json: {status: status, id: @credential.id}
      end
    end)
    account = create(:account)
    denied = account.two_factor_credentials.create!(otp_secret: "denied")
    allowed = account.two_factor_credentials.create!(otp_secret: "allowed")
    _, forbidden = dispatch_enrollment(:send_code, account: account, params: {id: denied.id})
    expect(forbidden.status).to eq(403)
    expect(denied.reload.verification_nonce).to be_nil
    _, response = dispatch_enrollment(:send_code, account: account, params: {id: allowed.id})
    expect(JSON.parse(response.body)).to eq("status" => "ok", "id" => allowed.id)
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

    _, edit = dispatch_enrollment(:edit, account: credential.account, params: {id: credential.id})
    expect(edit.body).to include("Resend verification code")
    _, resent = dispatch_enrollment(:send_code, account: credential.account, params: {id: credential.id})
    expect(resent.status).to eq(202)

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

  context "with a second credential model" do
    before do
      connection = ActiveRecord::Base.connection
      connection.execute("CREATE TEMPORARY TABLE enrollment_emails (LIKE two_factor_credentials INCLUDING DEFAULTS)")
      connection.add_column(:enrollment_emails, :local_part, :string)
      connection.add_column(:enrollment_emails, :domain, :string)
      stub_const("EnrollmentEmail", Class.new(ApplicationRecord))
      stub_const("EnrollmentAccount", Class.new(Account))
      EnrollmentAccount.has_many :enrollment_emails, foreign_key: :account_id
      File.write(File.join(@directory, "app/models/enrollment_email.rb"), <<~RUBY)
        class EnrollmentEmail < ApplicationRecord
          belongs_to :account
        end
      RUBY
      @original_controller = File.read(File.join(@directory, "app/controllers/generated_enrollments/two_factor_credentials_controller.rb"))
      @original_view = File.read(File.join(@directory, "app/views/generated_enrollments/two_factor_credentials/new.html.erb"))
      generator = Vouch::Generators::TwoFactorableGenerator.new(["EnrollmentEmail"],
        subject: ["local_part", "domain"], auth_scope: "user", controller_path: "generated_enrollments")
      generator.destination_root = @directory
      generator.invoke_all
      load File.join(@directory, "app/models/enrollment_email.rb")
      allow(Vouch.mapping_for(:user)).to receive(:two_factor_credential_associations).and_return([
        EnrollmentAccount.reflect_on_association(:two_factor_credentials),
        EnrollmentAccount.reflect_on_association(:enrollment_emails)
      ])
      @owner = EnrollmentAccount.find(create(:account).id)
      @email_codes = []
      allow_any_instance_of(EnrollmentEmail).to receive(:deliver_verification_code) { |_record, code| @email_codes << code }
    end

    after do
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS pg_temp.enrollment_emails")
      ActiveRecord::Base.connection.schema_cache.clear_data_source_cache!("enrollment_emails")
    end

    it "uses both models without replacing the first generated controller or view" do
      expect(File.read(File.join(@directory, "app/controllers/generated_enrollments/two_factor_credentials_controller.rb"))).to eq(@original_controller)
      expect(File.read(File.join(@directory, "app/views/generated_enrollments/two_factor_credentials/new.html.erb"))).to eq(@original_view)
      _, response = dispatch_enrollment(:new, account: @owner, params: {})
      expect(response.body).to include("credential_kind=two_factor_credentials", "credential_kind=enrollment_emails")

      _, response = dispatch_enrollment(:new, account: @owner, params: {credential_kind: "enrollment_emails"})
      expect(response.body).to include('name="enrollment_email[local_part]"', 'name="enrollment_email[domain]"')
      expect(response.body).not_to include('name="two_factor_credential[otp_secret]"')
    end

    it "creates, verifies, and enables the second model with only its permitted subject attributes" do
      session = {}
      controller, response = dispatch_enrollment(:create, account: @owner, session: session, params: {
        credential_kind: "enrollment_emails",
        enrollment_email: {local_part: "alex", domain: "example.test", account_id: create(:account).id,
          verified_at: Time.current, two_factor_enabled_at: Time.current}
      })
      email = controller.instance_variable_get(:@credential)
      expect(response.status).to eq(202)
      expect(email.account_id).to eq(@owner.id)
      expect(email).not_to be_verified
      expect(email).not_to be_two_factor_enabled
      expect(response.body).to include("credential_kind=enrollment_emails")

      _, response = dispatch_enrollment(:update, account: @owner, session: session,
        params: {credential_kind: "enrollment_emails", id: email.id, code: @email_codes.last})
      expect(response.status).to eq(302)
      expect(email.reload).to be_verified
      expect(email).to be_two_factor_enabled
      expect(@owner.reload).to be_two_factor_enabled
      expect(session).to be_empty
    end

    it "keeps overlapping IDs separate in management links, verification tokens, and deletion" do
      phone = @owner.two_factor_credentials.create!(id: 9001, otp_secret: "phone")
      email = @owner.enrollment_emails.create!(id: phone.id, local_part: "alex", domain: "example.test")
      session = {}
      [:two_factor_credentials, :enrollment_emails].each do |kind|
        _, response = dispatch_enrollment(:send_code, account: @owner, session: session,
          params: {credential_kind: kind.to_s, id: phone.id})
        expect(response.status).to eq(202)
      end
      expect(session.size).to eq(2)
      expect(session.values.uniq.size).to eq(2)

      _, response = dispatch_enrollment(:index, account: @owner, params: {})
      expect(response.body).to include("credential_kind=two_factor_credentials", "credential_kind=enrollment_emails")
      _, response = dispatch_enrollment(:destroy, account: @owner,
        params: {credential_kind: "enrollment_emails", id: email.id})
      expect(response.status).to eq(302)
      expect(EnrollmentEmail.exists?(email.id)).to be(false)
      expect(TwoFactorCredential.exists?(phone.id)).to be(true)
    end

    it "rejects missing or unknown kinds without selecting another model" do
      phone = @owner.two_factor_credentials.create!(otp_secret: "phone")
      [nil, "Account", "users"].each do |kind|
        _, response = dispatch_enrollment(:destroy, account: @owner,
          params: {credential_kind: kind, id: phone.id})
        expect(response.status).to eq(404)
      end
      expect(TwoFactorCredential.exists?(phone.id)).to be(true)
      _, response = dispatch_enrollment(:create, account: @owner,
        params: {enrollment_email: {local_part: "alex", domain: "example.test"}})
      expect(response.status).to eq(404)
    end

    it "does not manage the second model through another owner's account" do
      email = EnrollmentEmail.create!(account: create(:account), local_part: "other", domain: "example.test")
      %i[edit send_code update destroy].each do |action|
        _, response = dispatch_enrollment(action, account: @owner,
          params: {credential_kind: "enrollment_emails", id: email.id, code: "123456"})
        expect(response.status).to eq(404)
      end
      expect(@email_codes).to be_empty
      expect(email.reload).not_to be_verified
    end
  end

  def dispatch_enrollment(action, params:, account: create(:account), session: {})
    identity = create(:user, account: account)
    controller = GeneratedEnrollments::TwoFactorCredentialsController.new
    controller.class.prepend_view_path(File.join(@directory, "app/views"))
    allow(controller).to receive(:current_account).and_return(account)
    allow(controller).to receive(:current_identity).and_return(identity)
    allow(controller).to receive(:session).and_return(session)

    request = ActionDispatch::TestRequest.create
    method = {index: "GET", new: "GET", edit: "GET", update: "PATCH", destroy: "DELETE"}.fetch(action, "POST")
    request.set_header("REQUEST_METHOD", method)
    request.set_header("action_dispatch.request.parameters", params.stringify_keys)
    request.set_header("action_dispatch.request.path_parameters", {
      controller: "generated_enrollments/two_factor_credentials", action: action.to_s
    })
    response = ActionDispatch::TestResponse.new
    controller.dispatch(action.to_s, request, response)
    [controller, response]
  end
end
