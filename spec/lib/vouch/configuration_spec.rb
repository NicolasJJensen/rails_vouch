# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Configuration do
  subject(:config) { described_class.new }

  describe "top-level defaults" do
    it "leaves app_name nil so hosts must set it" do
      expect(config.app_name).to be_nil
    end

    it "sets credential_drafts_session_suffix to 'credential_drafts'" do
      expect(config.credential_drafts_session_suffix).to eq("credential_drafts")
    end

    it "sets the host integration defaults" do
      expect(config.parent_controller).to eq("ApplicationController")
      expect(config.authentication_callbacks).to eq([])
      expect(config.pending_authentication_ttl).to eq(10.minutes)
      expect(config.preserved_session_keys).to eq([])
      expect(config.preserved_auth_scopes).to eq([])
      expect(config.oauth_mfa_providers).to eq([])
      expect(config.authentication_policy).to eq("Vouch::AuthenticationPolicy")
      expect(config.install_middleware).to be(true)
    end
  end

  describe "lockable defaults" do
    it "sets max_failed_attempts to 5" do
      expect(config.lockable.max_failed_attempts).to eq(5)
    end

    it "inherits lockout_duration from root configuration" do
      expect(config.lockable.lockout_duration).to eq(30.minutes)
    end

    it "cascades a changed root lockout duration to every credential config" do
      config.lockout_duration = 7.minutes

      expect(config.lockable.lockout_duration).to eq(7.minutes)
      expect(config.verifiable.lockout_duration).to eq(7.minutes)
      expect(config.two_factorable.lockout_duration).to eq(7.minutes)
      expect(config.magic_linkable.lockout_duration).to eq(7.minutes)
      expect(config.recoverable.lockout_duration).to eq(7.minutes)
    end

    it "keeps an explicit lockable duration ahead of the root cascade" do
      config.lockable.lockout_duration = 11.minutes
      config.lockout_duration = 7.minutes

      expect(config.lockable.lockout_duration).to eq(11.minutes)
    end

    it "sets strategy to :failed_attempts" do
      expect(config.lockable.strategy).to eq(:failed_attempts)
    end

    it "does not invalidate established sessions when an account locks" do
      expect(config.lockable.invalidate_sessions_on_lockout).to be(false)
    end
  end

  describe "password_trackable defaults" do
    it "sets history_count to 5" do
      expect(config.password_trackable.history_count).to eq(5)
    end

    it "sets history_window to 1 month" do
      expect(config.password_trackable.history_window).to eq(1.month)
    end
  end

  describe "password_resetable defaults" do
    it "sets expiry to 15 minutes" do
      expect(config.password_resetable.expiry).to eq(15.minutes)
    end
  end

  describe "verifiable defaults" do
    it "sets max_attempts to 5" do
      expect(config.verifiable.max_attempts).to eq(5)
    end

    it "sets validity to 10 minutes" do
      expect(config.verifiable.validity).to eq(10.minutes)
    end

    it "sets length to 6" do
      expect(config.verifiable.length).to eq(6)
    end

    it "inherits lockout_duration from root configuration" do
      expect(config.verifiable.lockout_duration).to eq(30.minutes)
    end
  end

  describe "two_factorable defaults" do
    it "sets max_attempts to 5" do
      expect(config.two_factorable.max_attempts).to eq(5)
    end

    it "sets challenge_validity to 5 minutes" do
      expect(config.two_factorable.challenge_validity).to eq(5.minutes)
    end

    it "inherits lockout_duration from root configuration" do
      expect(config.two_factorable.lockout_duration).to eq(30.minutes)
    end
  end

  describe "recoverable defaults" do
    it "sets code_count to 10" do
      expect(config.recoverable.code_count).to eq(10)
    end

    it "sets code_length to 8" do
      expect(config.recoverable.code_length).to eq(8)
    end

    it "sets max_attempts to 10" do
      expect(config.recoverable.max_attempts).to eq(10)
    end

    it "sets low_threshold to 3" do
      expect(config.recoverable.low_threshold).to eq(3)
    end
  end

  describe "invitations defaults" do
    it "sets expiry to 7 days" do
      expect(config.invitations.expiry).to eq(7.days)
    end
  end

  describe "top-level defaults" do
    it "initializes empty login_resolvers" do
      expect(config.login_resolvers).to eq([])
    end
  end

  describe "#register_login_resolver" do
    it "registers a class-based resolver" do
      config.register_login_resolver Vouch::LoginResolver::EmailResolver

      expect(config.login_resolvers.last).to be_a(Vouch::LoginResolver::EmailResolver)
    end

    it "instantiates the resolver" do
      config.register_login_resolver Vouch::LoginResolver::EmailResolver

      resolver = config.login_resolvers.last
      expect(resolver).to respond_to(:valid?)
      expect(resolver).to respond_to(:resolve!)
    end

    it "resolves a named resolver through the current constant" do
      resolver_name = "ReloadableResolver"
      stub_const(resolver_name, Class.new(Vouch::LoginResolver::Base))
      config.register_login_resolver(resolver_name.constantize)
      first_class = config.login_resolver_classes.first

      stub_const(resolver_name, Class.new(Vouch::LoginResolver::Base))
      expect(config.login_resolver_classes.first).not_to equal(first_class)
    end
  end

  describe "#configure_warden" do
    it "preserves an existing shared manager default while scoping Vouch defaults" do
      observed = nil
      app = lambda do |env|
        observed = [env.fetch("warden").default_strategies,
                    env.fetch("warden").default_strategies(scope: :user)]
        [200, { "content-type" => "text/plain" }, ["ok"]]
      end
      manager = Warden::Manager.new(app) do |warden_config|
        warden_config.default_strategies(:host_strategy)
      end

      Vouch.configure_warden(manager)
      response = manager.call(Rack::MockRequest.env_for("/"))

      expect(response.first).to eq(200)
      expect(observed).to eq([[:host_strategy], [:password]])
    end
  end

end
