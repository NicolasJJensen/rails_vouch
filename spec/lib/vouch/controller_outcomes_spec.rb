# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::ControllerOutcomes do
  let(:controller) { Class.new { include Vouch::ControllerOutcomes }.new }

  def mapping_for(scope, **options)
    Vouch::Mapping.new(scope, **options).tap(&:resolve_reflections!)
  end

  it "returns a status and exposes operation details without requiring an authentication mapping" do
    error = StandardError.new("Verification failed")
    result = Vouch::Result.invalid(error: error, reason: :expired)

    expect(controller.send(:set_operation_result, result)).to eq(:invalid)
    expect(controller.instance_variable_get(:@operation_error)).to equal(error)
    expect(controller.instance_variable_get(:@failure_reason)).to eq(:expired)
  end

  it "does not resolve inherited authentication helpers for generic verification" do
    controller.define_singleton_method(:auth_mapping) { raise "No scope registered" }
    controller.instance_variable_set(:@verifiable, Object.new)
    expect(controller.send(:set_operation_result, Vouch::Result.ok)).to eq(:ok)
  end

  it "names the credentials record after the configured scope" do
    mapping = mapping_for(:operator, model: "Account")
    controller.define_singleton_method(:auth_mapping) { mapping }
    account = Account.new
    controller.instance_variable_set(:@vouch_account, account)

    controller.send(:set_operation_result, Vouch::Result.pending(account, next_step: :two_factor))

    expect(controller.instance_variable_get(:@operator)).to equal(account)
    expect(controller.instance_variable_get(:@next_step)).to eq(:two_factor)
  end

  it "exposes membership records and selection collections separately from credentials" do
    mapping = mapping_for(:member, account: "Account", identity: "User", tenant: "Organisation")
    controller.define_singleton_method(:auth_mapping) { mapping }
    account, identity = Account.new, User.new
    controller.instance_variable_set(:@vouch_account, account)
    controller.instance_variable_set(:@vouch_identities, [identity])

    controller.send(:set_operation_result, Vouch::Result.ok(account, identity: identity, committed: true))

    expect(controller.instance_variable_get(:@account)).to equal(account)
    expect(controller.instance_variable_get(:@member)).to equal(identity)
    expect(controller.instance_variable_get(:@members)).to eq([identity])
    expect(controller.instance_variable_get(:@registration_committed)).to be(true)
  end

  it "exposes a target identity when no account variable was assigned" do
    mapping = mapping_for(:operator, model: "Account")
    controller.define_singleton_method(:auth_mapping) { mapping }
    identity = Account.new
    controller.instance_variable_set(:@vouch_identity, identity)
    controller.send(:expose_authentication_records)
    expect(controller.instance_variable_get(:@operator)).to equal(identity)
  end

  it "rejects names that overwrite Rails request state" do
    mapping = mapping_for(:request, model: "Account")
    controller.define_singleton_method(:auth_mapping) { mapping }
    controller.instance_variable_set(:@vouch_account, Account.new)
    expect { controller.send(:expose_authentication_records) }
      .to raise_error(Vouch::ConfigurationError, /@request/)
  end

  it "keeps an identity-named parent separate from the selected membership" do
    parent = mapping_for(:identity, model: "Account")
    allow(Vouch).to receive(:mapping_for).with(:identity).and_return(parent)
    mapping = mapping_for(:member, account_scope: :identity, identity: "User", tenant: "Organisation")
    controller.define_singleton_method(:auth_mapping) { mapping }
    owner, member = Account.new, User.new
    controller.instance_variable_set(:@vouch_account, owner)
    controller.instance_variable_set(:@vouch_identity, member)

    2.times { controller.send(:expose_authentication_records) }

    expect(controller.instance_variable_get(:@identity)).to equal(owner)
    expect(controller.instance_variable_get(:@member)).to equal(member)
    expect(controller.instance_variable_get(:@vouch_identity)).to equal(member)
  end

  it "keeps an account-named membership separate from its credentials record" do
    parent = mapping_for(:login, model: "Account")
    allow(Vouch).to receive(:mapping_for).with(:login).and_return(parent)
    mapping = mapping_for(:account, account_scope: :login, identity: "User", tenant: "Organisation")
    controller.define_singleton_method(:auth_mapping) { mapping }
    owner, member = Account.new, User.new
    controller.instance_variable_set(:@vouch_account, owner)
    controller.instance_variable_set(:@vouch_identity, member)
    controller.instance_variable_set(:@vouch_identities, [member])

    2.times { controller.send(:expose_authentication_records) }

    expect(controller.instance_variable_get(:@login)).to equal(owner)
    expect(controller.instance_variable_get(:@account)).to equal(member)
    expect(controller.instance_variable_get(:@accounts)).to eq([member])
    expect(controller.instance_variable_get(:@vouch_account)).to equal(owner)
  end

  it "does not read a reassigned public alias back into the operation" do
    mapping = mapping_for(:account, model: "Account")
    controller.define_singleton_method(:auth_mapping) { mapping }
    owner = Account.new
    controller.instance_variable_set(:@vouch_account, owner)
    controller.send(:expose_authentication_records)
    controller.instance_variable_set(:@account, Account.new)

    controller.send(:set_operation_result, Vouch::Result.ok(owner))

    expect(controller.instance_variable_get(:@account)).to equal(owner)
    expect(controller.instance_variable_get(:@vouch_account)).to equal(owner)
  end

  it "reserves Vouch's internal record namespace" do
    mapping = mapping_for(:vouch_identity, model: "Account")
    controller.define_singleton_method(:auth_mapping) { mapping }
    controller.instance_variable_set(:@vouch_account, Account.new)

    expect { controller.send(:expose_authentication_records) }
      .to raise_error(Vouch::ConfigurationError, /@vouch_identity/)
  end

  it "rejects a credentials alias that collides with the membership collection" do
    parent = mapping_for(:users, model: "Account")
    allow(Vouch).to receive(:mapping_for).with(:users).and_return(parent)
    mapping = mapping_for(:user, account_scope: :users, identity: "User", tenant: "Organisation")
    controller.define_singleton_method(:auth_mapping) { mapping }
    controller.instance_variable_set(:@vouch_account, Account.new)
    controller.instance_variable_set(:@vouch_identities, [User.new])

    expect { controller.send(:expose_authentication_records) }
      .to raise_error(Vouch::ConfigurationError, /aliases conflict at @users/)
    expect(controller.instance_variable_defined?(:@users)).to be(false)
  end
end
