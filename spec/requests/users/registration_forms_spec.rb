# frozen_string_literal: true

require "rails_helper"
require "omniauth"

RSpec.describe "Host registration forms", type: :request do
  let(:form_class) do
    Class.new do
      include ActiveModel::Model

      attr_reader :owner
      attr_accessor :organisation_name, :fail_after_save

      def initialize(owner)
        @owner = owner
      end

      def email_address=(value)
        owner.email_address = value
      end

      def password=(value)
        owner.password = value
      end

      def password_confirmation=(value)
        owner.password_confirmation = value
      end

      def self.deserialize(data, owner)
        form = new(owner)
        owner.email_address = data["email_address"] if data.key?("email_address")
        form.organisation_name = data["organisation_name"]
        form
      end

      def serialize
        {"email_address" => owner.email_address, "organisation_name" => organisation_name}
      end

      def save!
        owner.save!
        Organisation.create!(name: organisation_name) if organisation_name.present?
        if fail_after_save
          errors.add(:base, "Profile could not be saved")
          return false
        end
        true
      end
    end
  end

  before do
    stub_const("ExampleSignupForm", form_class)
    @previous_form_class = ApplicationController._registration_form_class
    ApplicationController.registration_form ExampleSignupForm
    @previous_oauth_mode = Vouch.mapping_for(:user).oauth_registration
    Vouch.mapping_for(:user).oauth_registration = :form
    Users::RegistrationsController.define_method(:registration_form_params) do
      params.fetch(:account, ActionController::Parameters.new).permit(:email_address, :password, :password_confirmation, :organisation_name, :fail_after_save)
    end
  end

  after do
    ApplicationController._registration_form_class = @previous_form_class
    Vouch.mapping_for(:user).oauth_registration = @previous_oauth_mode
    Users::RegistrationsController.remove_method(:registration_form_params)
  end

  def save_step(attributes)
    Users::RegistrationsController.define_method(:create) do
      registration_form.assign_attributes(params.require(:account).permit(:email_address, :organisation_name))
      result = save_registration_form
      render json: {status: result.status, data: registration_form.serialize}
    end
    post "/users/sign_up", params: {account: attributes}
  ensure
    Users::RegistrationsController.remove_method(:create)
  end

  def submit(attributes = {})
    post "/users/sign_up", params: {account: {
      password: "password123", password_confirmation: "password123"
    }.merge(attributes)}
  end

  def connect(uid, email: "provider@example.test")
    oauth_callback "/users/auth/example/callback", purpose: :register,
      auth: OmniAuth::AuthHash.new(provider: "example", uid: uid, info: {email: email})
  end

  it "inherits one declaration and passes the positional credentials record to the form" do
    get "/users/sign_up"

    form = controller.view_assigns.fetch("registration_form")
    expect(form).to be_a(ExampleSignupForm)
    expect(form.owner).to equal(controller.view_assigns.fetch("account"))
    expect(Users::OmniAuthsController._registration_form_class).to eq(ExampleSignupForm)
  end

  it "restores wizard fields and saves associated records in the registration transaction" do
    save_step(email_address: "draft@example.test", organisation_name: "Profile companion")
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("registration_form").organisation_name).to eq("Profile companion")

    expect { submit }.to change(Account, :count).by(1).and change(Organisation, :count).by(2)

    expect(Account.last.email_address).to eq("draft@example.test")
    expect(response).to redirect_to("/")
    expect(session[Vouch::Session.key_for(:user, :registration_form)]).to be_nil
  end

  it "rolls back host writes when a save method returns false" do
    save_step(email_address: "draft@example.test", organisation_name: "Rolled back")

    expect { submit(fail_after_save: true) }.not_to change(Account, :count)

    expect(Organisation.where(name: "Rolled back")).not_to exist
    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("registration_form").errors[:base]).to include("Profile could not be saved")
  end

  it "supports a form with save instead of save!" do
    ExampleSignupForm.class_eval do
      alias_method :save, :save!
      undef_method :save!
    end
    submit(email_address: "save@example.test")
    expect(response).to redirect_to("/")
    expect(Account.find_by(email_address: "save@example.test")).to be_present
  end

  it "restores host fields before applying each OAuth provider" do
    save_step(email_address: "chosen@example.test", organisation_name: "Keep this profile")
    connect("first")
    connect("second", email: "second@example.test")
    get "/users/sign_up"

    form = controller.view_assigns.fetch("registration_form")
    expect(form.owner.email_address).to eq("chosen@example.test")
    expect(form.organisation_name).to eq("Keep this profile")
    expect { post "/users/sign_up", params: {account: {}} }.to change(Account, :count).by(1).and change(OmniAuthIdentity, :count).by(2)
    expect(Account.last.email_address).to eq("chosen@example.test")
  end

  it "uses the same form for automatic OAuth registration" do
    mapping = Vouch.mapping_for(:user)
    previous = mapping.oauth_registration
    mapping.oauth_registration = :automatic
    save_step(email_address: "automatic@example.test", organisation_name: "Automatic profile")

    expect { connect("automatic") }.to change(Account, :count).by(1).and change(Organisation, :count).by(2)
    expect(Account.last.email_address).to eq("automatic@example.test")
    expect(response).to redirect_to("/")
  ensure
    mapping.oauth_registration = previous
  end

  it "completes the invited owner through the form without a new tenant" do
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("registration_form").owner.id).to eq(account.id)
    counts = [Account.count, User.count, Organisation.count]

    submit

    expect(response).to redirect_to("/")
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    expect(account.reload.authenticate("password123")).to eq(account)
    expect(invitation.reload.invitation_accepted_at).to be_present
  end

  it "rolls back form records when an OAuth identity conflicts at completion" do
    save_step(email_address: "draft@example.test", organisation_name: "Rollback profile")
    connect("claimed")
    create(:account).omni_auth_identities.create!(provider: "example", uid: "claimed")
    counts = [Account.count, User.count, Organisation.count, OmniAuthIdentity.count]

    post "/users/sign_up", params: {account: {}}

    expect(response).to have_http_status(:unprocessable_entity)
    expect([Account.count, User.count, Organisation.count, OmniAuthIdentity.count]).to eq(counts)
  end

  it "does not retain a submitted password in the draft" do
    submit(email_address: "invalid", organisation_name: "Retain profile")

    draft = session[Vouch::Session.key_for(:user, :registration_form)]
    expect(draft.fetch("data")).to eq("email_address" => "invalid", "organisation_name" => "Retain profile")
    expect(draft.to_json).not_to include("password123")
  end

  it "rejects password fields in host serialization" do
    ExampleSignupForm.define_method(:serialize) { {"password" => "do-not-retain"} }
    expect { save_step(email_address: "draft@example.test") }.to raise_error(
      Vouch::ConfigurationError, /must not retain password/)
  end

  it "expires the whole form without extending its lifetime on another step" do
    save_step(email_address: "draft@example.test")
    travel Vouch.configuration.pending_authentication_ttl / 2 do
      save_step(organisation_name: "Later step")
    end
    travel Vouch.configuration.pending_authentication_ttl + 1 do
      expect { submit }.not_to change(Account, :count)
      expect(response).to redirect_to("/users/sign_up")
      expect(flash[:alert]).to include("expired")
    end
  end

  it "rejects a form from a different authentication context" do
    save_step(email_address: "draft@example.test")
    Users::RegistrationsController.define_method(:new) do
      session[Vouch::AuthenticationSession::CONTEXT_KEY] = "changed"
      super()
    end
    get "/users/sign_up"
    expect(response).to redirect_to("/users/sign_up")
    expect(flash[:alert]).to include("changed")
    expect(session[Vouch::Session.key_for(:user, :registration_form)]).to be_nil
  ensure
    Users::RegistrationsController.remove_method(:new)
  end
  it "accepts a custom form root and attributes assigned to the record only at save" do
    ExampleSignupForm.class_eval do
      attr_accessor :email_address, :password, :password_confirmation

      def save!
        owner.assign_attributes(email_address: email_address, password: password,
          password_confirmation: password_confirmation)
        owner.save!
        nil
      end
    end
    Users::RegistrationsController.define_method(:registration_form_params) do
      params.require(:signup).permit(:email_address, :password, :password_confirmation, :organisation_name)
    end

    post "/users/sign_up", params: {signup: {email_address: "custom@example.test",
      password: "password123", password_confirmation: "password123", organisation_name: "Form-only field"}}

    expect(response).to redirect_to("/")
    expect(Account.find_by!(email_address: "custom@example.test").authenticate("password123")).to be_present
  end

  it "renders ActiveModel form validation errors from save!" do
    ExampleSignupForm.define_method(:save!) do
      owner.save!
      errors.add(:base, "The profile needs a name")
      raise ActiveModel::ValidationError.new(self)
    end

    expect { submit(email_address: "model-error@example.test") }.not_to change(Account, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("registration_form").errors[:base]).to include("The profile needs a name")
  end

  it "retains the previous draft when a later step exceeds the size limit" do
    save_step(email_address: "draft@example.test", organisation_name: "Previous")
    save_step(organisation_name: "x" * 3_000)

    expect(response.parsed_body.fetch("status")).to eq("invalid")
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("registration_form").organisation_name).to eq("Previous")
  end

  it "preserves association records built by an invited form when locking its owner" do
    ExampleSignupForm.class_eval do
      def initialize(owner)
        @owner = owner
        owner.two_factor_credentials.build(type: "phone", otp_secret: "draft-secret")
      end
    end
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}

    expect { submit }.to change(TwoFactorCredential, :count).by(1)

    expect(response).to redirect_to("/")
    expect(account.reload.two_factor_credentials.count).to eq(1)
  end

  it "keeps committed registration when subsequent sign-in raises a validation error" do
    allow_any_instance_of(Users::RegistrationsController).to receive(:complete_sign_in).and_raise(
      ActiveModel::ValidationError.new(ExampleSignupForm.new(Account.new)))

    expect { submit(email_address: "committed@example.test") }.to change(Account, :count).by(1)

    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:notice]).to eq("Account created.")
    expect(flash[:alert]).to eq("Something went wrong signing in, please try again.")
  end

  it "shows failed credential restoration without deleting the serialized draft" do
    save_step(email_address: "draft@example.test", organisation_name: "Retain this")
    ExampleSignupForm.define_singleton_method(:deserialize) do |data, owner|
      raise Vouch::OperationFailed.new(Vouch::Result.invalid)
    end

    get "/users/sign_up"

    expect(response).to have_http_status(:ok)
    expect(controller.view_assigns.fetch("registration_form").errors[:base]).to include("A registration credential must be verified again.")
    original = session[Vouch::Session.key_for(:user, :registration_form)]
    expect { submit }.not_to change(Account, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(session[Vouch::Session.key_for(:user, :registration_form)]).to eq(original)
  end

  it "uses the same record when a host prepares its form before calling super" do
    Users::RegistrationsController.define_method(:create) do
      registration_form
      super()
    end

    expect { submit(email_address: "preloaded@example.test") }.to change(Account, :count).by(1)
    expect(response).to redirect_to("/")
  ensure
    Users::RegistrationsController.remove_method(:create)
  end

  it "completes an invited owner through the same form after connecting providers" do
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: {token: invitation.invitation_token, choice: "new"}
    connect("invited-first")
    connect("invited-second")
    counts = [Account.count, User.count, Organisation.count]

    post "/users/sign_up", params: {account: {}}

    expect(response).to redirect_to("/")
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    expect(account.reload.omni_auth_identities.pluck(:uid)).to contain_exactly("invited-first", "invited-second")
    expect(invitation.reload.invitation_accepted_at).to be_present
  end

  it "retains provider prefills in the form across a subsequent render" do
    connect("prefill", email: "prefill@example.test")
    get "/users/sign_up"

    expect(controller.view_assigns.fetch("registration_form").owner.email_address).to eq("prefill@example.test")
  end

  it "retains an explicit verification blocker across final submission retries" do
    ExampleSignupForm.class_eval do
      attr_accessor :verification_expired
      validate { errors.add(:base, "Verify the phone again") if verification_expired }
      alias_method :serialize_without_expiry, :serialize
      def serialize
        serialize_without_expiry.merge("verification_expired" => verification_expired)
      end
    end
    original_restore = ExampleSignupForm.method(:deserialize)
    ExampleSignupForm.define_singleton_method(:deserialize) do |data, owner|
      form = original_restore.call(data, owner)
      form.verification_expired = data["verification_expired"]
      form
    end
    Users::RegistrationsController.define_method(:create) do
      registration_form.owner.email_address = "expired@example.test"
      registration_form.verification_expired = true
      save_registration_form!
      head :no_content
    end
    post "/users/sign_up"
    Users::RegistrationsController.remove_method(:create)

    2.times do
      expect { submit }.not_to change(Account, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(controller.view_assigns.fetch("registration_form").errors[:base]).to include("Verify the phone again")
    end
  end

  context "with a verified MFA credential" do
    before do |example|
      @original_app = Rails.application.app
      stack = Rails.application.middleware.dup
      stack.swap(ActionDispatch::Session::CookieStore, ActionDispatch::Session::CacheStore,
        key: "_registration_form_session", cache: ActiveSupport::Cache::MemoryStore.new)
      Rails.application.instance_variable_set(:@app, stack.build(Rails.application.routes))
      allow_any_instance_of(TwoFactorCredential).to receive(:deliver_verification_code) { |_record, code| @verification_code = code }
      verified_at = example.metadata[:older_proof] ? 6.minutes.ago : Time.current
      travel_to(verified_at) do
        credential = TwoFactorCredential.new(type: "phone", otp_secret: "+61400000000")
        issued = credential.start_verification!
        credential.complete_verification!(@verification_code, token: issued.token)
        @verified_state = credential.serialize_verification_state
      end
      ExampleSignupForm.class_eval do
        attr_accessor :credential

        def self.deserialize(data, owner)
          form = new(owner)
          owner.email_address = data["email_address"]
          if data["credential"]
            form.credential = TwoFactorCredential.new
            form.credential.restore_verification_state!(data["credential"])
          end
          form
        end

        def serialize
          {"email_address" => owner.email_address,
            "credential" => credential&.serialize_verification_state}
        end

        def save!
          owner.save!
          credential.account = owner
          credential.save!
          credential.enable_two_factor!
          owner.enable_two_factor!
          if fail_after_save
            errors.add(:base, "Profile failed after MFA activation")
            return false
          end
          true
        end
      end
      Users::RegistrationsController.define_method(:registration_form_byte_limit) { 4.kilobytes }
      state = @verified_state
      Users::RegistrationsController.define_method(:create) do
        form = registration_form
        form.owner.email_address = "verified@example.test"
        form.credential = TwoFactorCredential.new
        form.credential.restore_verification_state!(state)
        result = save_registration_form
        head(result.ok? ? :no_content : :unprocessable_entity)
      end
      post "/users/sign_up"
      Users::RegistrationsController.remove_method(:create)
      expect(response).to have_http_status(:no_content)
    end

    after do
      Rails.application.instance_variable_set(:@app, @original_app)
      Users::RegistrationsController.remove_method(:registration_form_byte_limit)
    end

    it "saves the verified credential and MFA selection before committing registration" do
      expect { submit }.to change(Account, :count).by(1).and change(TwoFactorCredential, :count).by(1)

      account = Account.find_by!(email_address: "verified@example.test")
      credential = account.two_factor_credentials.sole
      expect(credential).to be_verified
      expect(credential.two_factor_enabled_at).to be_present
      expect(account).to be_two_factor_enabled
      expect(response).to redirect_to("/users/two_factor_challenges")
    end

    it "rejects an expired proof while keeping the unexpired registration draft", :older_proof do
      original = session[Vouch::Session.key_for(:user, :registration_form)]
      travel 5.minutes do
        expect { submit }.not_to change(Account, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(controller.view_assigns.fetch("registration_form").errors[:base]).to include("A registration credential must be verified again.")
        expect(session[Vouch::Session.key_for(:user, :registration_form)]).to eq(original)
      end
    end

    it "rolls back the owner and enabled credential when later form persistence fails" do
      expect { submit(fail_after_save: true) }.not_to change(Account, :count)

      expect(TwoFactorCredential.count).to eq(0)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(controller.view_assigns.fetch("registration_form").errors[:base]).to include("Profile failed after MFA activation")
    end
  end

end
