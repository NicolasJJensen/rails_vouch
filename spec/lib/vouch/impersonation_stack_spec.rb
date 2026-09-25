# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::ImpersonationStack do
  class StackWarden
    attr_accessor :raw_session

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

  before do
    warden.raw_session = session
    warden.set_user(operator, scope: :user)
  end

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
    expect(session[evidence_key]).to eq({"method" => "totp", "credential" => "operator"})

    session[evidence_key] = {"method" => "recovery_code", "credential" => "target"}
    described_class.stop!(warden: warden, session: session, target_mapping: mapping)

    expect(session[evidence_key]).to eq({"method" => "totp", "credential" => "operator"})
  end
  it "round trips serialized stack references and stores the original operator only once" do
    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: first_target)
    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: second_target)
    restored = JSON.parse(JSON.generate(session))
    stack = restored.fetch(described_class::SESSION_KEY)
    expect(stack.count { |entry| entry.key?("operator") }).to eq(1)
    expect(described_class.authorized_identity(restored, scope: :user)).to eq(second_target)
    expect(described_class.original(warden: warden, session: restored, scope: :user)).to eq(operator)
  end

  it "discards malformed impersonation state and its authenticated identities" do
    session[described_class::SESSION_KEY] = [{"source_scope" => "user", "target_scope" => "user"}]
    described_class.discard_invalid!(warden: warden, session: session)
    expect(session).not_to have_key(described_class::SESSION_KEY)
    expect(warden.user(:user)).to be_nil
    expect(described_class).not_to be_active(session)
  end

  it "does not recreate a target session removed directly through Warden" do
    described_class.start!(warden: warden, session: session, source_mapping: mapping,
      target_mapping: mapping, target: first_target)
    warden.logout(:user)
    expect(Vouch.authenticated_identity(warden, :user)).to be_nil
  end

end
