# frozen_string_literal: true
require "rails_helper"

RSpec.describe "Linked account scope configuration" do
  around do |example|
    originals = Vouch.mappings.dup
    example.run
  ensure
    Vouch.mappings.replace(originals)
    Vouch::ApplicationHelpers.refresh!
  end

  def register_account
    mapping = Vouch::Mapping.new(:account, model: "Account")
    mapping.resolve_reflections!
    Vouch.register_mapping(:account, mapping)
  end

  it "derives the credentials class from an explicit account scope" do
    register_account
    mapping = Vouch::Mapping.new(:member, account_scope: :account, identity: "User", tenant: "Organisation")
    mapping.resolve_reflections!
    expect(mapping.account_class).to eq(Account)
    expect(mapping.account_scope_name).to eq(:account)
    expect(mapping.current_helper_name).to eq(:current_account_member)
    Vouch.register_mapping(:member, mapping)
    expect(ApplicationController.new).to respond_to(:current_account_member, :current_member, :authenticate_member!)
    expect(ApplicationController.new).not_to respond_to(:current_member_account, :current_account_account)
  end

  it "rejects a linked scope that repeats or contradicts the account model" do
    register_account
    expect { Vouch::Mapping.new(:member, account_scope: :account, account: "Account", identity: "User") }
      .to raise_error(Vouch::ConfigurationError, /cannot be combined/)
  end

  it "rejects a membership scope as a parent" do
    expect { Vouch::Mapping.new(:member, account_scope: :user, identity: "User") }
      .to raise_error(Vouch::ConfigurationError, /single-model/)
  end

  it "rejects helper collisions before publishing a mapping" do
    register_account
    member = Vouch::Mapping.new(:member, account_scope: :account, identity: "User")
    Vouch.register_mapping(:member, member)
    conflicting = Vouch::Mapping.new(:account_member, model: "Account")
    expect { Vouch.register_mapping(:account_member, conflicting) }
      .to raise_error(Vouch::ConfigurationError, /helpers collide/)
    expect(Vouch.registered_scope?(:account_member)).to be(false)
  end
end
