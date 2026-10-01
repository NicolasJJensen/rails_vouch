require "rails_helper"
require "vouch/verification_rate_limit_store"

RSpec.describe Vouch::VerificationRateLimitStore do
  it "passes Rails' complete key and expiry to the shared store" do
    store = double("atomic shared cache")
    expect(store).to receive(:increment).with("rate-limit:verification:code-subject:Phone:[123]", 1, expires_in: 10.minutes).and_return(1)

    expect(described_class.new(store).increment("rate-limit:verification:code-subject:Phone:[123]", 1, expires_in: 10.minutes)).to eq(1)
  end

  it "fails closed when the backend cannot increment the counter" do
    [nil, false, 0, -1, "1"].each do |value|
      store = double("cache", increment: value)
      expect { described_class.new(store).increment("key", 1) }.to raise_error(described_class::Unavailable)
    end
  end

  it "rejects caches that cannot share counters across application processes" do
    [ActiveSupport::Cache::NullStore.new, ActiveSupport::Cache::MemoryStore.new].each do |store|
      expect { described_class.new(store) }.to raise_error(ArgumentError, /shared atomic/)
    end
  end

  it "does not hide unexpected backend errors" do
    store = double("cache")
    allow(store).to receive(:increment).and_raise(ArgumentError, "bad backend configuration")

    expect { described_class.new(store).increment("key", 1) }.to raise_error(ArgumentError, "bad backend configuration")
  end
  it "shares Rails' subject budget between saved-record and temporary controllers" do
    counts = Hash.new(0)
    cache = double("shared atomic cache")
    allow(cache).to receive(:increment) { |key, amount, **| counts[key] += amount }
    store = described_class.new(cache)
    temporary = Vouch::TemporaryVerificationsController.new
    saved = Vouch::VerificationsController.new
    [temporary, saved].each do |controller|
      controller.instance_variable_set(:@verifiable, PhoneVerification.new(e164: "+61412345678"))
    end
    options = { to: 1, within: 10.minutes, by: :verification_subject_key,
      with: -> { raise ActionController::TooManyRequests }, store: store,
      name: "code-subject", scope: "verification" }

    temporary.send(:rate_limiting, **options)
    expect { saved.send(:rate_limiting, **options) }.to raise_error(ActionController::TooManyRequests)
    expect(counts.values).to eq([2])
  end

end
