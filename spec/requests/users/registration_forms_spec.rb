# frozen_string_literal: true

require "rails_helper"
require "omniauth"

RSpec.describe "Host registration persistence", type: :request do
  let(:form_class) do
    Class.new do
      include ActiveModel::Model

      attr_reader :owner
      attr_accessor :organisation_name, :fail_after_save, :verification_state

      def initialize(owner)
        @owner = owner
      end

      %i[email_address password password_confirmation].each do |attribute|
        define_method("#{attribute}=") { |value| owner.public_send("#{attribute}=", value) }
      end

      def self.deserialize(data, owner)
        form = new(owner)
        form.assign_attributes(data || {})
        form
      end

      def serialize
        {"email_address" => owner.email_address, "organisation_name" => organisation_name,
          "verification_state" => verification_state}.compact
      end

      def save!
        raise ActiveModel::ValidationError.new(self) unless valid?

        owner.save!
        Organisation.create!(name: organisation_name) if organisation_name.present?
        if fail_after_save
          errors.add(:base, "Profile could not be saved")
          return false
        end
        nil
      end
    end
  end

  before do
    stub_const("ExampleSignupForm", form_class)
    @previous_oauth_mode = Vouch.mapping_for(:user).oauth_registration
    Vouch.mapping_for(:user).oauth_registration = :form
    Users::RegistrationsController.define_method(:new) do
      super()
      return if performed?

      @signup_form = ExampleSignupForm.deserialize(session[:signup], @account)
    end
    Users::RegistrationsController.define_method(:create) do
      if params[:step] == "details"
        @signup_form = ExampleSignupForm.deserialize(session[:signup], @account)
        @signup_form.assign_attributes(params.require(:signup).permit(:email_address, :organisation_name))
        session[:signup] = @signup_form.serialize
        return head :no_content
      end

      status = super() do |record|
        @signup_form = ExampleSignupForm.deserialize(session[:signup], record)
        @signup_form.assign_attributes(params.fetch(:signup, ActionController::Parameters.new)
          .permit(:email_address, :password, :password_confirmation, :organisation_name, :fail_after_save))
        @signup_form.save!
      end
      session.delete(:signup) if @registration_committed
      status
    end
  end

  after do
    Vouch.mapping_for(:user).oauth_registration = @previous_oauth_mode
    %i[new create].each { |action| Users::RegistrationsController.remove_method(action) }
    if Users::OmniAuthsController.instance_methods(false).include?(:callback)
      Users::OmniAuthsController.remove_method(:callback)
    end
  end

  def save_step(attributes)
    post "/users/sign_up", params: {step: "details", signup: attributes}
  end

  def submit(attributes = {})
    post "/users/sign_up", params: {signup: {
      password: "password123", password_confirmation: "password123"
    }.merge(attributes)}
  end

  def connect(uid, email: "provider@example.test")
    oauth_callback "/users/auth/example/callback", purpose: :register,
      auth: OmniAuth::AuthHash.new(provider: "example", uid: uid, info: {email: email})
  end

  def automatic_form_callback
    Users::OmniAuthsController.define_method(:callback) do
      status = super() do |record|
        @signup_form = ExampleSignupForm.deserialize(session[:signup], record)
        @signup_form.save!
      end
      session.delete(:signup) if @registration_committed
      status
    end
  end

  it "uses a positional record without a form-class declaration" do
    expect(ApplicationController).not_to respond_to(:registration_form)
    get "/users/sign_up"

    form = controller.view_assigns.fetch("signup_form")
    expect(form.owner).to equal(controller.view_assigns.fetch("account"))
    expect(response).to have_http_status(:ok)
  end

  it "prepares the exact registration record before host callbacks and the saving block" do
    Users::RegistrationsController.define_method(:set_signup) do
      @prepared_signup_record = @account
      @prepared_signup_form = ExampleSignupForm.new(@account)
    end
    Users::RegistrationsController.before_action :set_signup, only: [:new, :create]

    get "/users/sign_up"
    expect(controller.view_assigns.fetch("prepared_signup_record")).to equal(controller.view_assigns.fetch("account"))

    submit(email_address: "prepared@example.test")

    expect(response).to redirect_to("/")
    expect(controller.view_assigns.fetch("prepared_signup_form").owner)
      .to equal(controller.view_assigns.fetch("signup_form").owner)
  ensure
    Users::RegistrationsController.skip_before_action :set_signup
    Users::RegistrationsController.remove_method(:set_signup)
  end

  it "halts an invalid OAuth context before host form callbacks or persistence" do
    connect("context")
    Warden.on_next_request do |proxy|
      proxy.raw_session[Vouch::AuthenticationSession::CONTEXT_KEY] = SecureRandom.hex(32)
    end
    Users::RegistrationsController.define_method(:set_signup) { raise "Must not prepare a stale form" }
    Users::RegistrationsController.before_action :set_signup, only: :create

    expect { submit }.not_to change(Account, :count)
    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:alert]).to include("session changed")
  ensure
    Users::RegistrationsController.skip_before_action :set_signup
    Users::RegistrationsController.remove_method(:set_signup)
  end

  it "restores a host-owned wizard at the same URL and saves its records atomically" do
    save_step(email_address: "draft@example.test", organisation_name: "Profile companion")
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("signup_form").organisation_name).to eq("Profile companion")

    expect { submit }.to change(Account, :count).by(1).and change(Organisation, :count).by(2)

    expect(Account.last.email_address).to eq("draft@example.test")
    expect(response).to redirect_to("/")
    expect(session[:signup]).to be_nil
  end

  it "rolls back all writes when the persistence block returns false" do
    save_step(email_address: "draft@example.test", organisation_name: "Rolled back")

    expect { submit(fail_after_save: true) }.not_to change(Account, :count)

    expect(Organisation.where(name: "Rolled back")).not_to exist
    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
    expect(controller.view_assigns.fetch("signup_form").errors[:base]).to include("Profile could not be saved")
    expect(session[:signup]).to include("organisation_name" => "Rolled back")
  end

  it "cancels a block that returns nil without saving the supplied record" do
    ExampleSignupForm.define_method(:save!) { nil }
    expect { submit(email_address: "unsaved@example.test") }.not_to change(Account, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
  end

  it "does not save the owner twice when the block returns nil after saving" do
    allow_any_instance_of(Users::RegistrationsController).to receive(:complete_sign_in).and_return(:signed_in)
    writes = []
    allow_any_instance_of(Account).to receive(:save!).and_wrap_original do |method, *args, **kwargs|
      writes << method.receiver.email_address
      method.call(*args, **kwargs)
    end
    submit(email_address: "once@example.test")
    expect(response).to redirect_to("/")
    expect(writes.count("once@example.test")).to eq(1)
  end

  it "rolls back a form when an owner callback raises RecordNotSaved" do
    cancel = proc { raise ActiveRecord::RecordNotSaved.new("Save cancelled", self) }
    Account.after_create(cancel)
    save_step(email_address: "cancelled@example.test", organisation_name: "Cancelled profile")

    expect { submit }.not_to change(Account, :count)
    expect(Organisation.where(name: "Cancelled profile")).not_to exist
    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
    expect(controller.view_assigns.fetch("registration_committed")).to be(false)
    expect(controller.send(:current_identity)).to be_nil
    expect(session[:signup]).to include("email_address" => "cancelled@example.test")
  ensure
    Account.skip_callback(:create, :after, cancel)
  end

  it "rolls back the owner and related writes when a related callback raises RecordNotSaved" do
    cancel = proc { raise ActiveRecord::RecordNotSaved.new("Profile save cancelled", self) }
    Organisation.after_create(cancel)

    expect {
      submit(email_address: "related@example.test", organisation_name: "Cancelled companion")
    }.not_to change(Account, :count)
    expect(Organisation.where(name: "Cancelled companion")).not_to exist
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
    expect(controller.view_assigns.fetch("operation_error").record).to be_a(Organisation)
    expect(controller.send(:current_identity)).to be_nil
  ensure
    Organisation.skip_callback(:create, :after, cancel)
  end

  it "rolls back the owner when a related record fails validation" do
    validate = proc { errors.add(:name, "is unavailable") }
    Organisation.validate(validate)

    expect {
      submit(email_address: "invalid-related@example.test", organisation_name: "Invalid companion")
    }.not_to change(Account, :count)
    expect(Organisation.where(name: "Invalid companion")).not_to exist
    expect(controller.view_assigns.fetch("operation_status")).to eq(:invalid)
    expect(controller.view_assigns.fetch("operation_error").record.errors[:name]).to include("is unavailable")
    expect(controller.send(:current_identity)).to be_nil
  ensure
    Organisation.skip_callback(:validate, :before, validate)
  end

  it "uses the supplied record without reading Rails' internal save status" do
    allow_any_instance_of(Account).to receive(:_last_transaction_return_status).and_raise("Unexpected Rails internals access")

    submit(email_address: "public-contract@example.test")

    expect(response).to redirect_to("/")
    expect(controller.view_assigns.fetch("registration_committed")).to be(true)
  end

  it "does not accept an invitation when its existing owner's save is cancelled" do
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}
    cancel = proc { raise ActiveRecord::RecordNotSaved.new("Save cancelled", self) }
    Account.after_update(cancel)

    submit

    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
    expect(account.reload.password_digest).to be_nil
    expect(account).to be_registration_required
    expect(invitation.reload.invitation_accepted_at).to be_nil
    expect(controller.send(:current_identity)).to be_nil
  ensure
    Account.skip_callback(:update, :after, cancel) if cancel
  end

  it "does not link providers or sign in after a cancelled automatic OAuth save" do
    Vouch.mapping_for(:user).oauth_registration = :automatic
    automatic_form_callback
    cancel = proc { raise ActiveRecord::RecordNotSaved.new("Save cancelled", self) }
    Account.after_create(cancel)

    expect { connect("cancelled") }.not_to change(Account, :count)
    expect(OmniAuthIdentity.where(uid: "cancelled")).not_to exist
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
    expect(controller.send(:current_identity)).to be_nil
  ensure
    Account.skip_callback(:create, :after, cancel)
  end

  it "preserves host draft choices alongside multiple provider proofs" do
    save_step(email_address: "chosen@example.test", organisation_name: "Keep this profile")
    connect("first")
    connect("second", email: "second@example.test")
    get "/users/sign_up"

    form = controller.view_assigns.fetch("signup_form")
    expect(form.owner.email_address).to eq("chosen@example.test")
    expect(form.organisation_name).to eq("Keep this profile")
    expect { post "/users/sign_up" }.to change(Account, :count).by(1).and change(OmniAuthIdentity, :count).by(2)
    expect(Account.last.email_address).to eq("chosen@example.test")
  end

  it "uses the same host form in the automatic OAuth persistence block" do
    Vouch.mapping_for(:user).oauth_registration = :automatic
    automatic_form_callback
    save_step(email_address: "automatic@example.test", organisation_name: "Automatic profile")

    expect { connect("automatic") }.to change(Account, :count).by(1).and change(Organisation, :count).by(2)
    expect(Account.last.email_address).to eq("automatic@example.test")
    expect(response).to redirect_to("/")
  end

  it "does not yield the automatic persistence block for a form continuation" do
    Users::OmniAuthsController.define_method(:callback) do
      super() { raise "Persistence should not run" }
    end
    expect { connect("form") }.not_to change(Account, :count)
    expect(response).to redirect_to("/users/sign_up")
  end

  it "does not yield the persistence block for ordinary OAuth sign-in or linking" do
    user = create(:user)
    user.account.omni_auth_identities.create!(provider: "example", uid: "existing")
    Users::OmniAuthsController.define_method(:callback) do
      super() { raise "Persistence should not run" }
    end
    oauth_callback "/users/auth/example/callback", purpose: :sign_in,
      auth: OmniAuth::AuthHash.new(provider: "example", uid: "existing")
    expect(response).to redirect_to("/")
    oauth_callback "/users/auth/example/callback", purpose: :link,
      auth: OmniAuth::AuthHash.new(provider: "example", uid: "another")
    expect(response).to redirect_to("/")
    expect(user.account.omni_auth_identities.count).to eq(2)
  end

  it "completes the invited owner without creating another tenant" do
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("signup_form").owner.id).to eq(account.id)
    counts = [Account.count, User.count, Organisation.count]

    submit

    expect(response).to redirect_to("/")
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    expect(account.reload.authenticate("password123")).to eq(account)
    expect(invitation.reload.invitation_accepted_at).to be_present
  end

  it "rolls back associated writes when an OAuth identity conflicts" do
    save_step(email_address: "draft@example.test", organisation_name: "Rollback profile")
    connect("claimed")
    create(:account).omni_auth_identities.create!(provider: "example", uid: "claimed")
    counts = [Account.count, User.count, Organisation.count, OmniAuthIdentity.count]

    post "/users/sign_up"

    expect(response).to have_http_status(:unprocessable_entity)
    expect([Account.count, User.count, Organisation.count, OmniAuthIdentity.count]).to eq(counts)
  end

  it "accepts attributes assigned only when the host saves the form" do
    ExampleSignupForm.class_eval do
      attr_accessor :email_address, :password, :password_confirmation

      def save!
        owner.assign_attributes(email_address: email_address, password: password,
          password_confirmation: password_confirmation)
        owner.save!
        nil
      end
    end
    submit(email_address: "deferred@example.test")
    expect(response).to redirect_to("/")
    expect(Account.last.email_address).to eq("deferred@example.test")
  end

  it "retains ActiveModel form validation errors and rolls back partial writes" do
    ExampleSignupForm.define_method(:save!) do
      owner.save!
      errors.add(:base, "The profile needs a name")
      raise ActiveModel::ValidationError.new(self)
    end

    expect { submit(email_address: "model-error@example.test") }.not_to change(Account, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("signup_form").errors[:base]).to include("The profile needs a name")
    expect(controller.view_assigns.fetch("operation_error")).to be_a(ActiveModel::ValidationError)
  end

  it "keeps committed registration if subsequent sign-in raises a validation error" do
    allow_any_instance_of(Users::RegistrationsController).to receive(:complete_sign_in).and_raise(
      ActiveModel::ValidationError.new(ExampleSignupForm.new(Account.new)))

    expect { submit(email_address: "committed@example.test") }.to change(Account, :count).by(1)
    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:notice]).to eq("Account created.")
    expect(flash[:alert]).to eq("Something went wrong signing in, please try again.")
  end

  it "completes the same invited owner after connecting multiple providers" do
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}
    connect("invited-first")
    connect("invited-second")
    counts = [Account.count, User.count, Organisation.count]

    post "/users/sign_up"

    expect(response).to redirect_to("/")
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    expect(account.reload.omni_auth_identities.pluck(:uid)).to contain_exactly("invited-first", "invited-second")
    expect(invitation.reload.invitation_accepted_at).to be_present
  end

  it "rolls back an automatic OAuth form that cancels" do
    Vouch.mapping_for(:user).oauth_registration = :automatic
    Users::OmniAuthsController.define_method(:callback) do
      super() do |record|
        record.save!
        Organisation.create!(name: "Rollback automatic profile")
        false
      end
    end
    expect { connect("cancelled") }.not_to change(Account, :count)
    expect(Organisation.where(name: "Rollback automatic profile")).not_to exist
    expect(controller.view_assigns.fetch("operation_status")).to eq(:cancelled)
    expect(response).to redirect_to("/users/sign_in")
  end

  context "with a verified MFA credential" do
    before do
      allow_any_instance_of(TwoFactorCredential).to receive(:deliver_verification_code) { |_record, code| @verification_code = code }
      credential = TwoFactorCredential.new(type: "phone", otp_secret: "+61400000000")
      issued = credential.start_verification!
      credential.complete_verification!(@verification_code, token: issued.token)
      @verified_state = credential.serialize_verification_state
      ExampleSignupForm.class_eval do
        def save!
          credential = TwoFactorCredential.new
          credential.restore_verification_state!(verification_state)
          owner.save!
          credential.account = owner
          credential.save!
          credential.enable_two_factor!
          owner.enable_two_factor!
          return false if fail_after_save

          nil
        end
      end
      state = @verified_state
      Users::RegistrationsController.define_method(:create) do
        super() do |record|
          @signup_form = ExampleSignupForm.new(record)
          @signup_form.assign_attributes(params.require(:signup).permit(:email_address, :password, :password_confirmation, :fail_after_save))
          @signup_form.verification_state = state
          @signup_form.save!
        end
      end
    end

    it "saves and enables the selected credential in the registration transaction" do
      expect { submit(email_address: "verified@example.test") }.to change(Account, :count).by(1).and change(TwoFactorCredential, :count).by(1)
      account = Account.find_by!(email_address: "verified@example.test")
      credential = account.two_factor_credentials.sole
      expect(credential).to be_verified
      expect(credential.two_factor_enabled_at).to be_present
      expect(account).to be_two_factor_enabled
      expect(response).to redirect_to("/users/two_factor_challenges")
    end

    it "rejects expired proof without saving registration" do
      travel Vouch.configuration.pending_authentication_ttl + 1 do
        expect { submit(email_address: "expired@example.test") }.not_to change(Account, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(controller.view_assigns.fetch("operation_error")).to be_a(Vouch::OperationFailed)
      end
    end

    it "rolls back the owner and enabled credential if the block cancels" do
      expect { submit(email_address: "rollback@example.test", fail_after_save: true) }.not_to change(Account, :count)
      expect(TwoFactorCredential.count).to eq(0)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
