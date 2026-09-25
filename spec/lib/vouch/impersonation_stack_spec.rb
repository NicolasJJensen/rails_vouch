# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::ImpersonationStack do
  class StackWarden
    def initialize
      @users = {}
    end

    def user(scope)
      @users[scope]
    end

    def set_user(record, scope:, **)
      @users[scope] = record
    end

    def logout(*scopes)
      scopes.each { |scope| @users.delete(scope) }
    end
  end

  let(:mapping) { Vouch.mapping_for(:user) }
  let(:organisation) { create(:organisation) }
  let(:operator) { create(:user, organisation: organisation) }
  let(:first_target) { create(:user, organisation: organisation) }
  let(:second_target) { create(:user, organisation: organisation) }
  let(:warden) { StackWarden.new }
  let(:session) { {} }

  before { warden.set_user(operator, scope: :user) }

  it "restores one level at a time and restores the original operator when stopping all" do
    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: first_target, return_to: "/first")
    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: second_target, return_to: "/second")

    expect(warden.user(:user)).to eq(second_target)
    expect(described_class.original(warden: warden, session: session, scope: :user)).to eq(operator)

    described_class.stop!(warden: warden, session: session, target_mapping: mapping)
    expect(warden.user(:user)).to eq(first_target)

    described_class.stop_all!(warden: warden, session: session, target_mapping: mapping)
    expect(warden.user(:user)).to eq(operator)
  end

  it "does not restore an operator whose authentication fingerprint changed" do
    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: first_target)
    operator.account.update!(password: "changed-password123", password_confirmation: "changed-password123")

    expect(described_class.stop!(warden: warden, session: session, target_mapping: mapping)).to be_nil
    expect(warden.user(:user)).to be_nil
  end

  it "keeps MFA evidence with the impersonated context and restores the operator's evidence" do
    evidence_key = Vouch::Session.key_for(mapping.evidence_scope_name, :evidence)
    session[evidence_key] = {"method" => "totp", "credential" => "operator"}

    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: first_target)
    expect(session[evidence_key]).to be_nil

    session[evidence_key] = {"method" => "recovery_code", "credential" => "target"}
    described_class.stop!(warden: warden, session: session, target_mapping: mapping)

    expect(session[evidence_key]).to eq({"method" => "totp", "credential" => "operator"})
  end
end
