# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Result do
  it "keeps an intermediate authentication step distinct from success" do
    account = Account.new
    result = described_class.pending(account, next_step: :two_factor)

    expect(result).to be_pending
    expect(result).not_to be_ok
    expect(result).not_to be_success
    expect(result.value).to equal(account)
    expect(result.metadata[:next_step]).to eq(:two_factor)
  end

  it "retains the original error and field errors for a custom controller response" do
    account = Account.new
    account.errors.add(:password, "has already been used")
    error = ActiveRecord::RecordInvalid.new(account)
    result = described_class.invalid(error: error, record: account, committed: false)

    expect(result.error).to equal(error)
    expect(result.metadata[:record].errors[:password]).to eq(["has already been used"])
    expect(result.metadata[:committed]).to be(false)
  end

  it "distinguishes committed registration from unsuccessful authentication" do
    result = described_class.invalid(committed: true, next_step: :sign_in)

    expect(result).to be_invalid
    expect(result.metadata).to include(committed: true, next_step: :sign_in)
  end
end
