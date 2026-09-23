# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::LifecycleHooks do
  self.use_transactional_tests = false

  let(:controller_class) do
    Class.new do
      include ActiveHooks::Callbacks
      include Vouch::LifecycleHooks
      define_hooks :save, :commit_of_save

      def run_save
        run_commit_hooks(:save) { yield if block_given?; true }
      end

      def run_authenticated_save
        run_authentication_hooks(:save) { yield if block_given?; true }
      end
    end
  end

  it "runs commit callbacks inside the transaction" do
    calls = []
    controller_class.set_hook(:commit_of_save, :before, -> { calls << [:before, ActiveRecord::Base.connection.open_transactions] })
    controller_class.set_hook(:commit_of_save, :after, -> { calls << [:after, ActiveRecord::Base.connection.open_transactions] })

    controller_class.new.run_save

    expect(calls).to all(satisfy { |(_, transactions)| transactions.positive? })
  end

  it "rolls back when a commit before callback halts" do
    controller_class.set_hook(:commit_of_save, :before, -> { throw(:abort) })
    account = Account.new(email_address: "after-hook-#{SecureRandom.hex(6)}@example.com",
      password: "password123", password_confirmation: "password123")

    result = controller_class.new.run_save { account.save! }

    expect(result).to be(false)
    expect(account).not_to be_persisted
  ensure
    account&.destroy
  end

  it "rolls back when an around callback does not yield" do
    controller_class.set_hook(:commit_of_save, :around, ->(_operation) { :cached })
    account = Account.new(email_address: "around-hook-#{SecureRandom.hex(6)}@example.com",
      password: "password123", password_confirmation: "password123")

    result = controller_class.new.run_save { account.save! }

    expect(result).to be(false)
    expect(account).not_to be_persisted
  ensure
    account&.destroy
  end

  it "rejects an enclosing joinable transaction before lifecycle callbacks run" do
    calls = []
    controller_class.set_hook(:save, :before, -> { calls << :before })

    expect do
      ActiveRecord::Base.transaction do
        controller_class.new.run_authenticated_save
      end
    end.to raise_error(Vouch::ConfigurationError, /existing joinable transaction/)

    expect(calls).to be_empty
  end

  it "reports an outer around callback that does not yield as cancelled" do
    controller_class.set_hook(:save, :around, ->(_operation) { :cached })

    expect(controller_class.new.run_authenticated_save).to be(false)
  end
end
