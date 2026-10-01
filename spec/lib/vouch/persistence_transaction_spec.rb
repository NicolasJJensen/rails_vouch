# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Persistence do
  self.use_transactional_tests = false

  before do
    @record_class = Class.new(ActiveRecord::Base) do
      self.table_name = "accounts"
    end
    @record = @record_class.create!(email_address: "transaction-#{SecureRandom.hex(8)}@example.com", password_digest: "digest")
  end

  after do
    @record_class.where(id: @record.id).delete_all if @record
  end

  it "rejects a root transaction rolled back by a before-commit callback" do
    @record_class.before_commit { raise ActiveRecord::Rollback }

    expect {
      described_class.transaction(@record) { @record.update!(email_address: "changed@example.com") }
    }.to raise_error(Vouch::Persistence::Cancelled)

    expect(@record.reload.email_address).not_to eq("changed@example.com")
  end

  it "returns a legitimate nil result from a committed transaction" do
    result = described_class.transaction(@record) do
      @record.update!(email_address: "changed@example.com")
      nil
    end

    expect(result).to be_nil
    expect(@record.reload.email_address).to eq("changed@example.com")
  end

  it "returns a successful savepoint result before its outer transaction commits" do
    @record_class.transaction do
      result = described_class.transaction(@record) do
        @record.update!(email_address: "changed@example.com")
        :saved
      end
      expect(result).to eq(:saved)
      expect(@record.reload.email_address).to eq("changed@example.com")
      raise ActiveRecord::Rollback
    end

    expect(@record.reload.email_address).not_to eq("changed@example.com")
  end

  it "rejects an explicit rollback inside a savepoint" do
    @record_class.transaction do
      expect {
        described_class.transaction(@record) do
          @record.update!(email_address: "changed@example.com")
          raise ActiveRecord::Rollback
        end
      }.to raise_error(Vouch::Persistence::Cancelled)
      expect(@record.reload.email_address).not_to eq("changed@example.com")
    end
  end
end
