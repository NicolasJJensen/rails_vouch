# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Authenticatable do
  describe ".authenticates_with" do
    it "records enabled features" do
      expect(Account.auth_features).to include(:lockable, :password_resetable, :password_trackable, :two_factorable, :omniauthable)
    end

    it "raises for unknown features" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        include Vouch::Authenticatable
      end
      expect { klass.authenticates_with(:nonexistent) }.to raise_error(ArgumentError, /Unknown auth feature/)
    end

    it "accumulates features and merges options across declarations" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        include Vouch::Authenticatable

        authenticates_with :lockable, lockable: {max_failed_attempts: 20}
        authenticates_with :password_trackable, lockable: {lockout_duration: 2.hours}
      end

      expect(klass.auth_features).to contain_exactly(:lockable, :password_trackable)
      expect(klass.auth_options).to eq(
        lockable: {max_failed_attempts: 20, lockout_duration: 2.hours}
      )
      expect(klass.auth_feature_enabled?(:lockable)).to be(true)
      expect(klass.auth_feature_enabled?(:password_trackable)).to be(true)
    end

    it "leaves existing declarations unchanged when a later declaration is invalid" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        include Vouch::Authenticatable

        authenticates_with :lockable, lockable: {max_failed_attempts: 20}
      end

      expect {
        klass.authenticates_with :password_trackable, :nonexistent,
          password_trackable: {history_count: 5}
      }.to raise_error(ArgumentError, /Unknown auth feature/)

      expect(klass.auth_features).to eq([:lockable])
      expect(klass.auth_options).to eq(lockable: {max_failed_attempts: 20})
      expect(klass.auth_feature_enabled?(:password_trackable)).to be(false)
    end
  end

  describe ".auth_config" do
    it "returns global config value when no model override" do
      expect(Account.auth_config(:lockable, :max_failed_attempts)).to eq(5)
    end

    it "returns nested config values" do
      expect(Account.auth_config(:lockable, :max_failed_attempts)).to eq(Vouch.configuration.lockable.max_failed_attempts)
      expect(Account.auth_config(:lockable, :lockout_duration)).to eq(Vouch.configuration.lockable.lockout_duration)
      expect(Account.auth_config(:password_trackable, :history_count)).to eq(Vouch.configuration.password_trackable.history_count)
    end

    it "returns model override when set" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        include Vouch::Authenticatable
        authenticates_with :lockable, lockable: { max_failed_attempts: 20 }
      end
      expect(klass.auth_config(:lockable, :max_failed_attempts)).to eq(20)
    end

    it "applies each two_factorable override independently and falls back per key" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        include Vouch::Authenticatable
        authenticates_with :two_factorable,
          two_factorable: {max_attempts: 0, length: false, challenge_validity: nil}
      end

      expect(klass.auth_config(:two_factorable, :max_attempts)).to eq(0)
      expect(klass.auth_config(:two_factorable, :length)).to be(false)
      expect(klass.auth_config(:two_factorable, :challenge_validity))
        .to eq(Vouch.configuration.two_factorable.challenge_validity)
      expect(klass.auth_config(:two_factorable, :lockout_duration))
        .to eq(Vouch.configuration.two_factorable.lockout_duration)
    end

    it "returns the sub-config namespace with single-arg form" do
      expect(Account.auth_config(:lockable)).to eq(Vouch.configuration.lockable)
    end
  end

  describe ".auth_feature_enabled?" do
    it "returns true for enabled features" do
      expect(Account.auth_feature_enabled?(:lockable)).to be true
    end

    it "returns false for disabled features" do
      expect(Account.auth_feature_enabled?(:invitable)).to be false
    end
  end

  describe "#auth_config" do
    it "delegates to class method" do
      account = build(:account)
      expect(account.auth_config(:lockable, :max_failed_attempts)).to eq(Account.auth_config(:lockable, :max_failed_attempts))
    end
  end

  describe "#successful_login!" do
    it "is defined as a hook point" do
      account = create(:account)
      expect(account).to respond_to(:successful_login!)
    end
  end

  describe "#failed_login!" do
    it "is defined as a hook point" do
      account = create(:account)
      expect(account).to respond_to(:failed_login!)
    end
  end
end
