# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::OperationFailed do
  it "retains the unsuccessful result and its field-error context" do
    account = Account.new
    account.errors.add(:password, "has already been used")
    result = Vouch::Result.new(:invalid, nil, record: account)

    expect { raise described_class, result }.to raise_error(described_class) { |error|
      expect(error.result).to equal(result)
      expect(error.result.metadata[:record].errors[:password]).to eq(["has already been used"])
    }
  end

  it "identifies the outcome without putting sensitive result data in the message" do
    result = Vouch::Result.new(:locked, "private-token", identifier: "private@example.com")
    error = described_class.new(result)

    expect(error.message).to eq("Authentication operation failed (locked)")
    expect(error.result.value).to eq("private-token")
  end
end
