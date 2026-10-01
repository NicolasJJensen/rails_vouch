# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MFA route declarations" do
  let(:routes) { ActionDispatch::Routing::RouteSet.new }

  after { Vouch.deregister_mapping(:route_mfa) }

  def draw(&features)
    routes.draw do
      Vouch::RouteBuilder.new(self).scope(:route_mfa, model: "Account", path: "security", as: :member, &features)
    end
  end

  it "defines the challenge routes independently with the existing controller and helper names" do
    draw { |auth| auth.two_factor_challenges }
    helpers = routes.url_helpers
    expect(helpers.member_two_factor_challenges_path).to eq("/security/two_factor_challenges")
    expect(helpers.member_two_factor_challenge_path(7)).to eq("/security/two_factor_challenges/7")
    expect(helpers.send_code_member_two_factor_challenge_path(7)).to eq("/security/two_factor_challenges/7/send_code")
    expect(helpers.member_recovery_two_factor_challenge_path).to eq("/security/recovery")
    expect(helpers.member_consume_recovery_two_factor_challenge_path).to eq("/security/recovery")
    expect(helpers).not_to respond_to(:member_two_factor_credentials_path, :member_recovery_codes_path)
    expect(routes.routes.map { |route| route.defaults[:controller] }.uniq).to eq(["route_mfas/two_factor_challenge"])
    expect(routes.routes.map { |route| [route.defaults[:action], route.verb] }).to contain_exactly(
      ["index", "GET"], ["show", "GET"], ["update", "PATCH|PUT"], ["send_code", "POST"],
      ["destroy", "DELETE"], ["recovery", "GET"], ["consume_recovery", "POST"]
    )
  end

  it "defines credential management without adding challenge or recovery routes" do
    draw { |auth| auth.two_factor_credentials }
    helpers = routes.url_helpers
    expect(helpers.member_two_factor_credentials_path).to eq("/security/two_factor_credentials")
    expect(helpers.new_member_two_factor_credential_path).to eq("/security/two_factor_credentials/new")
    expect(helpers.member_two_factor_credential_path(7)).to eq("/security/two_factor_credentials/7")
    expect(helpers).not_to respond_to(:member_two_factor_challenges_path, :member_recovery_codes_path)
    expect(routes.routes.map { |route| [route.defaults[:action], route.verb] }).to contain_exactly(
      ["index", "GET"], ["new", "GET"], ["create", "POST"], ["update", "PATCH|PUT"], ["destroy", "DELETE"]
    )
  end

  it "defines recovery-code management independently" do
    draw { |auth| auth.recovery_codes }
    expect(routes.url_helpers.member_recovery_codes_path).to eq("/security/recovery_codes")
    expect(routes.url_helpers).not_to respond_to(:member_two_factor_challenges_path, :member_two_factor_credentials_path)
    expect(routes.routes.map { |route| [route.defaults[:action], route.verb] }).to contain_exactly(
      ["show", "GET"], ["create", "POST"]
    )
  end

  {
    two_factor_challenges: %i[index show update send_code destroy recovery consume_recovery],
    two_factor_credentials: %i[index new create update destroy],
    recovery_codes: %i[show create]
  }.each do |feature, actions|
    it "supports a custom controller, URL, and full helper name for every #{feature} action" do
      overrides = actions.to_h { |action| [action, "custom/#{action}/:id"] }
      names = actions.to_h { |action| [action, "chosen_#{action}"] }
      draw { |auth| auth.public_send(feature, controller: "portal/custom", paths: overrides, path_names: names) }
      mapping = Vouch.mapping_for(:route_mfa)

      actions.each do |action|
        expect(mapping.route_path(feature, action, routes.url_helpers, id: 7)).to eq("/security/custom/#{action}/7")
        expect(routes.url_helpers.public_send("chosen_#{action}_path", 7)).to eq("/security/custom/#{action}/7")
      end
      expect(routes.routes.map { |route| route.defaults[:controller] }.uniq).to eq(["portal/custom"])
    end

    it "rejects unknown #{feature} customization keys" do
      expect { draw { |auth| auth.public_send(feature, paths: {unknown: "missing"}) } }
        .to raise_error(Vouch::ConfigurationError, /Unknown #{feature} paths: unknown/)
      expect { draw { |auth| auth.public_send(feature, path_names: {unknown: :missing}) } }
        .to raise_error(Vouch::ConfigurationError, /Unknown #{feature} path_names: unknown/)
    end

    it "keeps #{feature} on the credentials scope instead of a membership" do
      expect do
        draw do |auth|
          auth.membership :route_mfa_member, model: "User", tenant: "Organisation" do
            auth.public_send(feature)
          end
        end
      end.to raise_error(Vouch::ConfigurationError, /Configure credential routes on :route_mfa, not membership scope :route_mfa_member/)
    end
  end

  it "requires distinct helper names when actions use different paths" do
    expect { draw { |auth| auth.recovery_codes(paths: {create: "generate-recovery"}) } }
      .to raise_error(Vouch::ConfigurationError, /same path or distinct path_names/)
  end

  it "no longer exposes the bundled declaration" do
    expect(Vouch::RouteBuilder.instance_methods).not_to include(:two_factor)
  end
end
