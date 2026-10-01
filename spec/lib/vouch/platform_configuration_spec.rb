# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Platform configuration" do
  let(:config) { Vouch::Configuration.new }
  let(:email) { Vouch::LoginResolver::EmailResolver }

  it "replaces lists, keeps empty model overrides, and resets to current defaults" do
    config.login_resolvers = [email]
    config.login_resolvers = [email]
    expect(config.login_resolver_classes).to eq([email])
    config.login_resolvers_for "Account", with: []
    expect(config.login_resolvers(model: Account)).to eq([])
    expect(config.login_resolver_classes(model: User)).to eq([email])
    config.login_resolvers = []
    config.reset_login_resolvers_for Account
    expect(config.login_resolvers(model: Account)).to eq([])
    config.login_resolvers = [email]
    expect(config.login_resolver_classes(model: Account)).to eq([email])
  end

  it "isolates model-specific schemas and preserves ordered fresh instances" do
    first = Class.new(Vouch::LoginResolver::Base)
    second = Class.new(Vouch::LoginResolver::Base)
    config.login_resolvers_for Account, with: [first, second]
    expect(config.login_resolver_classes(model: Account)).to eq([first, second])
    expect(config.login_resolvers(model: User)).to eq([])
    expect(config.login_resolvers(model: Account).first).not_to equal(config.login_resolvers(model: Account).first)
  end

  it "rejects unsupported Rails versions in its dependencies" do
    specification = Gem::Specification.load(File.expand_path("../../../rails_vouch.gemspec", __dir__))
    requirement = specification.dependencies.find { |dependency| dependency.name == "railties" }.requirement
    expect(requirement.satisfied_by?(Gem::Version.new("8.0.9"))).to be(false)
    expect(requirement.satisfied_by?(Gem::Version.new("8.1.0"))).to be(true)
    expect(requirement.satisfied_by?(Gem::Version.new("9.0.0"))).to be(false)
  end

  it "rejects a non-list instead of silently interpreting configuration" do
    expect { config.login_resolvers = email }.to raise_error(Vouch::ConfigurationError, /Array/)
  end

  describe "account lookup" do
    before do
      allow(Vouch).to receive(:configuration).and_return(config)
    end

    it "normalizes input and uses the case-insensitive email column" do
      account = create(:account)
      account.update_columns(email_address: "Mixed@Example.COM")
      config.login_resolvers = [email]
      expect(Account.first_by_auth_conditions(email_address: " Mixed@example.com ")).to eq(account)
    end

    it "rejects different accounts found by overlapping resolvers" do
      first_account, second_account = create_list(:account, 2)
      resolvers = [first_account, second_account].map do |record|
        Class.new(Vouch::LoginResolver::Base) do
          define_method(:valid?) { |_params| true }
          define_method(:resolve!) { |_params, _model| success!(record) }
        end
      end
      config.login_resolvers = resolvers
      expect(Account.first_by_auth_conditions(login: "overlapping")).to be_nil
      config.login_resolvers = [resolvers.first, resolvers.first]
      expect(Account.first_by_auth_conditions(login: "overlapping")).to eq(first_account)
    end
  end

  describe "independent route configuration" do
    around do |example|
      originals = Vouch.mappings.dup
      example.run
    ensure
      Vouch.mappings.replace(originals)
      Vouch::ApplicationHelpers.refresh!
    end

    it "keeps default controllers independent of URL and helper prefixes" do
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw do
        Vouch::RouteBuilder.new(self).scope(:customer, model: "Account", path: "portal", as: :visitor) do |auth|
          auth.sessions
          auth.password_resets
          auth.two_factor_challenges
          auth.two_factor_credentials
          auth.recovery_codes
          auth.invitations
          auth.impersonation
          auth.oauth_callbacks
        end
      end
      expect(routes.routes.map { |r| r.defaults[:controller] }.uniq).to match_array(%w[
        customers/sessions customers/password_resets customers/two_factor_challenge
        customers/two_factor_credentials customers/recovery_codes customers/invitations
        customers/impersonations customers/omni_auths
      ])
      expect(routes.url_helpers.new_visitor_session_path).to eq("/portal/sign_in")
    end

    it "rejects a nested declaration with a conflicting parent" do
      routes = ActionDispatch::Routing::RouteSet.new
      expect do
        routes.draw do
          Vouch::RouteBuilder.new(self).scope(:owner, model: "Account") do |auth|
            auth.membership(:member, model: "User", account_scope: :another) { |nested| nested.sessions }
          end
        end
      end.to raise_error(Vouch::ConfigurationError, /Nested account_scope/)
    end
  end
end
