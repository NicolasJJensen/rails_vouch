# frozen_string_literal: true

require "rails_helper"
require "omniauth"
require "erb"
require "fileutils"
require "tmpdir"

RSpec.describe "Users::OmniAuths", type: :request do
  describe "GET /users/auth/failure" do
    it "redirects to sign-in with alert" do
      get "/users/auth/failure", params: { message: "invalid_credentials" }
      expect(response).to redirect_to("/users/sign_in")
    end
  end

  describe "GET /users/auth/:provider/callback" do
    let(:oauth_hash) do
      OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "12345",
        info: OmniAuth::AuthHash::InfoHash.new(
          email: "oauth@example.com",
          name: "OAuth User"
        )
      )
    end

    context "with an existing linked identity" do
      it "signs in the existing user" do
        account = create(:account, email_address: "oauth@example.com")
        user = create(:user, account: account)
        OmniAuthIdentity.create!(account: account, provider: "google_oauth2", uid: "12345")

        # Pass omniauth.auth directly in the Rack env
        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        expect(response).to redirect_to("/")
      end
    end

    context "when signed in (linking a new identity)" do
      it "links the identity to the current account" do
        user = create(:user)
        sign_in(user)

        expect {
          get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        }.to change(OmniAuthIdentity, :count).by(1)

        expect(response).to redirect_to("/")
      end

      it "handles duplicate provider+uid gracefully" do
        user = create(:user)
        sign_in(user)

        # Simulate a race condition: find_by returns nil, but the identity
        # was created by another request before the insert completes
        allow(OmniAuthIdentity).to receive(:find_by)
          .with(provider: "google_oauth2", uid: "12345")
          .and_return(nil)

        OmniAuthIdentity.create!(account: user.account, provider: "google_oauth2", uid: "12345")

        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        expect(response).to redirect_to("/")
        expect(flash[:alert]).to include("Already linked")
      end
    end

    context "when creating a new account" do
      def with_generated_registration_view
        source = File.read(Rails.root.join("..", "..", "lib/generators/vouch/scope/templates/registrations_new.html.erb.tt"))
        context = Object.new
        context.instance_variable_set(:@account_param_key, "account")
        context.instance_variable_set(:@tenant_class, "Organisation")
        context.instance_variable_set(:@tenant_param_key, "organisation")
        template = ERB.new(source).result(context.instance_eval { binding })
        original_view_paths = Users::RegistrationsController.view_paths

        Dir.mktmpdir("vouch-oauth-registration-view") do |directory|
          view_path = File.join(directory, "users", "registrations")
          FileUtils.mkdir_p(view_path)
          File.write(File.join(view_path, "new.html.erb"), template)
          Users::RegistrationsController.prepend_view_path(directory)
          yield
        end
      ensure
        Users::RegistrationsController.view_paths = original_view_paths if original_view_paths
      end

      def with_form_registration
        mapping = Vouch.mapping_for(:user)
        original = mapping.oauth_registration
        mapping.oauth_registration = :form
        yield
      ensure
        mapping.oauth_registration = original
      end

      it "creates an account, user, and organisation" do
        expect {
          get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }
        }.to change(Account, :count).by(1)
          .and change(User, :count).by(1)
          .and change(Organisation, :count).by(1)

        expect(response).to redirect_to("/")
      end

      it "uses the registration form by default without persisting callback records" do
        with_form_registration do
          counts = [Account.count, User.count, OmniAuthIdentity.count]

          get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => oauth_hash}

          expect(response).to redirect_to("/users/sign_up")
          expect([Account.count, User.count, OmniAuthIdentity.count]).to eq(counts)

          observed = nil
          allow(Account).to receive(:new_from_omniauth).and_wrap_original do |method, auth|
            observed = auth
            method.call(auth)
          end
          get "/users/sign_up"
          expect(response).to have_http_status(:ok)
          expect(observed.info.email).to eq("oauth@example.com")
        end
      end

      it "renders the generated OAuth registration form with mapped fields and no password inputs" do
        with_form_registration do
          with_generated_registration_view do
            get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => oauth_hash}
            get "/users/sign_up"

            expect(response.body).to include('action="/users/sign_up"')
            expect(response.body).to include('value="oauth@example.com"')
            expect(response.body).to include('name="organisation[name]"')
            expect(response.body).not_to include('name="account[password]"')
            expect(response.body).not_to include('name="account[password_confirmation]"')
          end
        end
      end

      it "renders password inputs in the generated ordinary registration form" do
        with_generated_registration_view do
          get "/users/sign_up"

          expect(response.body).to include('name="account[password]"')
          expect(response.body).to include('name="account[password_confirmation]"')
        end
      end

      it "can defer signup to the host registration form without persisting callback records" do
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_required?).and_return(true)
        counts = [Account.count, User.count, OmniAuthIdentity.count]

        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }

        expect(response).to redirect_to("/users/sign_up")
        expect([Account.count, User.count, OmniAuthIdentity.count]).to eq(counts)

        post "/users/sign_up", params: {account: {email_address: "oauth@example.com", password: "password123", password_confirmation: "password123"}}

        expect(response).to redirect_to("/")
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_present
      end

      it "expires a deferred OAuth signup context without accepting provider identity from params" do
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_required?).and_return(true)
        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }

        travel Vouch.configuration.pending_authentication_ttl + 1.second do
          post "/users/sign_up", params: {account: {email_address: "restart@example.com", password: "password123", password_confirmation: "password123"}, provider: "google_oauth2", uid: "12345"}
        end

        expect(response).to redirect_to("/users/sign_in")
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_nil
      end

      it "retains a valid deferred OAuth context across registration validation errors" do
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_required?).and_return(true)
        get "/users/auth/google_oauth2/callback", env: { "omniauth.auth" => oauth_hash }

        post "/users/sign_up", params: {account: {email_address: "invalid-address", password: "password123", password_confirmation: "password123"}}
        expect(response).to have_http_status(:unprocessable_content)
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_nil

        post "/users/sign_up", params: {account: {email_address: "oauth@example.com", password: "password123", password_confirmation: "password123"}}
        expect(response).to redirect_to("/")
        expect(OmniAuthIdentity.find_by(provider: "google_oauth2", uid: "12345")).to be_present
      end

      it "keeps the generated OAuth password when blank password fields are submitted" do
        with_form_registration do
          get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => oauth_hash}

          post "/users/sign_up", params: {account: {
            email_address: "oauth@example.com", password: "", password_confirmation: ""
          }}

          expect(response).to redirect_to("/")
          expect(Account.find_by!(email_address: "oauth@example.com").password_digest).to be_present
        end
      end

      it "reports automatic registration validation failures to the host override" do
        invalid_hash = oauth_hash.deep_dup
        invalid_hash.info.email = "invalid-address"
        observed = nil
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_failed)
          .and_wrap_original do |method, *args, **kwargs|
            observed = kwargs
            method.call(*args, **kwargs)
          end

        allow_any_instance_of(Vouch::AuthenticationSession).to receive(:oauth_initiation_return_to)
          .and_return("/projects?tab=access")

        expect {
          get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => invalid_hash}
        }.not_to change(Account, :count)

        expect(response).to redirect_to("/projects?tab=access")
        expect(observed).to include(reason: :validation, error: an_instance_of(ActiveRecord::RecordInvalid))
      end

      it "lets unexpected automatic registration failures propagate" do
        allow(Account).to receive(:new_from_omniauth).and_raise(RuntimeError, "unexpected OAuth failure")

        expect {
          get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => oauth_hash}
        }.to raise_error(RuntimeError, "unexpected OAuth failure")
      end

      it "reports an aborted automatic registration to the host override" do
        original_hooks = Users::OmniAuthsController.__hooks
        Users::OmniAuthsController.before_oauth_account_creation { throw :abort }
        observed = nil
        allow_any_instance_of(Users::OmniAuthsController).to receive(:oauth_registration_failed)
          .and_wrap_original do |method, *args, **kwargs|
            observed = kwargs
            method.call(*args, **kwargs)
          end

        expect {
          get "/users/auth/google_oauth2/callback", env: {"omniauth.auth" => oauth_hash}
        }.not_to change(Account, :count)

        expect(response).to redirect_to("/users/sign_in")
        expect(observed).to eq(reason: :aborted)
      ensure
        Users::OmniAuthsController.__hooks = original_hooks if original_hooks
      end
    end
  end
end
