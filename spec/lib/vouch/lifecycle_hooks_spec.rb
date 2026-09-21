# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::LifecycleHooks do
  self.use_transactional_tests = false

  let(:controller_class) do
    Class.new do
      include ActiveHooks::Callbacks
      include Vouch::LifecycleHooks
      define_hooks :save

      def run_save
        execution = prepare_lifecycle_hooks(:save)
        completed = run_lifecycle_operation(execution) { true }
        finish_lifecycle_hooks(execution, completed: completed)
      end
    end
  end

  it "defers after callbacks to Active Record's outer commit boundary" do
    calls = []
    controller_class.set_hook(:save, :after, -> { calls << :after })
    expect(ActiveRecord).to receive(:after_all_transactions_commit).and_yield

    controller_class.new.run_save

    expect(calls).to eq([:after])
  end

  it "runs after callbacks only when an enclosing transaction commits" do
    calls = []
    controller_class.set_hook(:save, :after, -> { calls << :after })

    ActiveRecord::Base.transaction do
      controller_class.new.run_save
      expect(calls).to be_empty
    end

    expect(calls).to eq([:after])
  end

  it "discards after callbacks when an enclosing transaction rolls back" do
    calls = []
    controller_class.set_hook(:save, :after, -> { calls << :after })

    ActiveRecord::Base.transaction do
      controller_class.new.run_save
      raise ActiveRecord::Rollback
    end

    expect(calls).to be_empty
  end

  it "does not roll back committed work when an after callback fails" do
    controller_class.set_hook(:save, :after, -> { raise "after failure" })
    account = Account.new(email_address: "after-hook-#{SecureRandom.hex(6)}@example.com",
      password: "password123", password_confirmation: "password123")

    expect do
      Account.transaction do
        account.save!
        controller_class.new.run_save
      end
    end.to raise_error(RuntimeError, "after failure")

    expect(Account.exists?(account.id)).to be(true)
  ensure
    account&.destroy
  end

  it "does not schedule after callbacks when the lifecycle operation halts" do
    controller_class.set_hook(:save, :before, -> { throw(:abort) })
    expect(ActiveRecord).not_to receive(:after_all_transactions_commit)

    controller_class.new.run_save
  end
end
