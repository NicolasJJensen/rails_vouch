# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::LoginResolution do
  describe ".first_by_auth_conditions" do
    let!(:account) { create(:account, email_address: "resolver@example.com") }

    it "finds an account via the registered resolver" do
      result = Account.first_by_auth_conditions({ "email_address" => "resolver@example.com" }.with_indifferent_access)
      expect(result).to eq(account)
    end

    it "returns nil when no resolver matches" do
      result = Account.first_by_auth_conditions({ "email_address" => "nobody@example.com" }.with_indifferent_access)
      expect(result).to be_nil
    end

    it "returns nil when params have no matching keys" do
      result = Account.first_by_auth_conditions({ "phone" => "555-1234" }.with_indifferent_access)
      expect(result).to be_nil
    end

    it "tries resolvers in order and returns first match" do
      config = Vouch.configuration

      # Prepend a resolver that's always valid but always fails
      noop_resolver = Class.new(Vouch::LoginResolver::Base) do
        def valid?(params) = true
        def resolve!(params, account_class) = fail!
      end
      resolver_names = config.instance_variable_get(:@login_resolver_names)
      original_names = resolver_names.dup
      resolver_names.unshift(noop_resolver)

      result = Account.first_by_auth_conditions({ "email_address" => "resolver@example.com" }.with_indifferent_access)
      expect(result).to eq(account)
    ensure
      config.instance_variable_set(:@login_resolver_names, original_names) if original_names
    end
  end
end
