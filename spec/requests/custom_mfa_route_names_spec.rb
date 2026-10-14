# frozen_string_literal: true

require "rails_helper"
require "erb"
require "tmpdir"
require "rails/generators"
require "generators/vouch/two_factorable/two_factorable_generator"

RSpec.describe "Custom MFA routes with generated views", type: :request do
  let(:account) { create(:account, password: "password123", password_confirmation: "password123") }
  let!(:credential) do
    account.two_factor_credentials.create!(otp_secret: ROTP::Base32.random,
      verified_at: Time.current, two_factor_enabled_at: Time.current)
  end

  before do
    @mappings = Vouch.mappings.dup
    @views = Dir.mktmpdir("vouch-custom-mfa-views")
    stub_const("PortalMfa", Module.new)
    {
      "Sessions" => Vouch::SessionsController,
      "TwoFactorChallenge" => Vouch::TwoFactorChallengeController,
      "RecoveryCodes" => Vouch::RecoveryCodesController
    }.each do |name, parent|
      klass = Class.new(parent) { auth_scope :account }
      stub_const("PortalMfa::#{name}Controller", klass)
      klass.prepend_view_path(@views)
    end
    generator = Vouch::Generators::TwoFactorableGenerator.new(["TwoFactorCredential"],
      auth_scope: "account", controller_path: "portal_mfa", subject: ["otp_secret"])
    generator.destination_root = @views
    generator.invoke(:create_optional_ui)
    load File.join(@views, "app/controllers/portal_mfa/two_factor_credentials_controller.rb")
    PortalMfa::TwoFactorCredentialsController.prepend_view_path(File.join(@views, "app/views"))
    {
      two_factor_challenge: %w[index show recovery],
      recovery_codes: %w[show]
    }.each do |controller, actions|
      FileUtils.mkdir_p(File.join(@views, "portal_mfa", controller.to_s))
      actions.each do |action|
        source = File.expand_path("../../lib/generators/vouch/two_factorable/templates/#{controller}_#{action}.html.erb.tt", __dir__)
        File.write(File.join(@views, "portal_mfa", controller.to_s, "#{action}.html.erb"), ERB.new(File.read(source)).result)
      end
    end
    Rails.application.routes.draw do
      Vouch.routes(self) do |auth|
        auth.scope model: "Account", path: "security" do
          auth.sessions controller: "portal_mfa/sessions"
          auth.two_factor_challenges(
            controller: "portal_mfa/two_factor_challenge",
            paths: {index: "mfa", show: "mfa/:id", update: "mfa/:id/check", send_code: "mfa/:id/send",
                    destroy: "cancel-mfa", recovery: "emergency", consume_recovery: "emergency/use"},
            path_names: {index: :mfa_choices, show: :mfa_credential, update: :check_mfa, send_code: :send_mfa,
                         destroy: :cancel_mfa, recovery: :emergency_code, consume_recovery: :use_emergency_code}
          )
          auth.two_factor_credentials(
            controller: "portal_mfa/two_factor_credentials",
            paths: {index: "factors", new: "factors/new", create: "enroll", update: "factors/:id/enable", destroy: "factors/:id/remove"},
            path_names: {index: :my_factors, new: :new_factor, create: :enroll_factor, update: :enable_factor, destroy: :remove_factor}
          )
          auth.recovery_codes(
            controller: "portal_mfa/recovery_codes",
            paths: {show: "backup-codes", create: "backup-codes/regenerate"},
            path_names: {show: :my_codes, create: :replace_codes}
          )
        end
      end
      root "rails/health#show"
    end
    account.enable_two_factor!
    allow_any_instance_of(TwoFactorCredential).to receive(:challenge).and_return(Vouch::Result.ok("test-token"))
  end

  after do
    Vouch.mappings.replace(@mappings)
    Vouch::ApplicationHelpers.refresh!
    Rails.application.reload_routes!
    FileUtils.rm_rf(@views)
  end

  def start_sign_in
    post "/security/sign_in", params: {email_address: account.email_address, password: "password123"}
    expect(response).to redirect_to("/security/mfa")
  end

  it "uses custom paths for challenge links, submission, resending, cancellation and failures" do
    start_sign_in
    get "/security/mfa"
    id = "two_factor_credential-#{credential.id}"
    expect(response.body).to include("/security/mfa/#{id}", "/security/cancel-mfa")
    get "/security/mfa/#{id}"
    expect(response.body).to include("/security/mfa/#{id}/check", "/security/mfa/#{id}/send")
    get "/security/mfa/missing"
    expect(response).to redirect_to("/security/mfa")
    delete "/security/cancel-mfa"
    expect(response).to redirect_to("/security/sign_in")
    expect(Vouch.mapping_for(:account).failure_path_for(:two_factor_challenges, Rails.application.routes.url_helpers)).to eq("/security/mfa")
  end

  it "renders recovery forms, completes authentication, and manages factors with custom helpers" do
    code = account.generate_recovery_codes!.value.first
    start_sign_in
    get "/security/mfa"
    expect(response.body).to include("/security/emergency")
    get "/security/emergency"
    expect(response.body).to include('action="/security/emergency/use"', 'action="/security/cancel-mfa"')
    post "/security/emergency/use", params: {recovery_owner_type: "Account", recovery_code: code}
    expect(response).to redirect_to("/")

    get "/security/backup-codes"
    expect(response.body).to include("/security/backup-codes/regenerate")
    post "/security/backup-codes/regenerate", params: {recovery_owner_type: "Account"}
    expect(response).to have_http_status(:created)
    expect(response.body).to include("/security/backup-codes/regenerate")

    get "/security/factors"
    expect(response.body).to include("/security/factors/#{credential.id}/remove", "/security/factors/new")
    delete "/security/factors/#{credential.id}/remove"
    expect(response).to redirect_to("/security/factors")
    expect(TwoFactorCredential.exists?(credential.id)).to be(false)
  end

  it "renders the generated selector when no credential-management routes are installed" do
    Rails.application.routes.draw do
      Vouch.routes(self) do |auth|
        auth.scope model: "Account", path: "security" do
          auth.sessions controller: "portal_mfa/sessions"
          auth.two_factor_challenges controller: "portal_mfa/two_factor_challenge"
        end
      end
      root "rails/health#show"
    end
    credential.destroy!
    post "/security/sign_in", params: {email_address: account.email_address, password: "password123"}
    expect(response).to redirect_to("/security/two_factor_challenges")
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No eligible authentication methods are available.")
    expect(response.body).not_to include("Add an authentication method")
  end
end
