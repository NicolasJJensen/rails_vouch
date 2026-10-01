# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Authenticatable do
  describe "#invalidate_authentication_sessions!" do
    it "invalidates saved fingerprints and increments from the current database value" do
      stub_const("VersionedAccount", Class.new(Account) do
        alias_attribute :auth_session_version, :consecutive_locks
      end)
      account = VersionedAccount.find(create(:account).id)
      stale = VersionedAccount.find(account.id)
      fingerprint = Vouch::PendingAuthentication.fingerprint(account)

      account.invalidate_authentication_sessions!
      stale.invalidate_authentication_sessions!

      expect(account.reload.auth_session_version).to eq(2)
      expect(Vouch::PendingAuthentication.fingerprint(account)).not_to eq(fingerprint)
    end

    it "offers a cancelled result and a strict bang failure for session invalidation" do
      stub_const("VersionedAccount", Class.new(Account) { alias_attribute :auth_session_version, :consecutive_locks })
      account = VersionedAccount.find(create(:account).id)
      allow(account).to receive(:update!).and_raise(ActiveRecord::RecordNotSaved.new("cancelled", account))
      expect(account.invalidate_authentication_sessions).to be_cancelled
      expect { account.invalidate_authentication_sessions! }
        .to raise_error(Vouch::OperationFailed) { |error| expect(error.result.error).to be_a(ActiveRecord::RecordNotSaved) }
      expect(account.reload.auth_session_version).to eq(0)
    end

    it "does not report invalidation when a before-commit callback rolls it back", use_transactional_fixtures: false do
      stub_const("VersionedAccount", Class.new(Account) { alias_attribute :auth_session_version, :consecutive_locks })
      account = VersionedAccount.find(create(:account).id)
      callback = proc { raise ActiveRecord::Rollback }
      VersionedAccount.before_commit(&callback)

      expect(account.invalidate_authentication_sessions).to be_cancelled
      expect(account.reload.auth_session_version).to eq(0)
    ensure
      VersionedAccount.skip_callback(:before_commit, :before, callback) if callback
      account&.destroy!
    end

    it "explains the required schema on models without the version column" do
      expect { create(:account).invalidate_authentication_sessions! }
        .to raise_error(Vouch::ConfigurationError, /auth_session_version/)
    end
  end

  describe "manual account locking" do
    it "returns a record result and raises the same failed result through the bang method" do
      account = create(:account)
      expect(account.lock_account.value).to eq(account)
      expect(account.reload).to be_locked
      allow(account).to receive(:update!).and_raise(ActiveRecord::RecordNotSaved.new("cancelled", account))
      expect(account.lock_account).to be_cancelled
      expect { account.lock_account! }.to raise_error(Vouch::OperationFailed)
    end
  end

  describe ".authenticates_with" do
    it "rejects negative history limits before changing a model's feature declarations" do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        include Vouch::Authenticatable
      end
      expect { klass.authenticates_with :password_trackable, password_trackable: { history_count: -1 } }
        .to raise_error(Vouch::ConfigurationError, /nonnegative integer/)
      expect(klass.auth_features).to be_empty
      expect { klass.authenticates_with :password_trackable, password_trackable: { history_window: -1.day } }
        .to raise_error(Vouch::ConfigurationError, /nonnegative duration/)
      expect { klass.authenticates_with :password_trackable, password_trackable: { history_count: 0, history_window: 0.days } }
        .not_to raise_error
    end

    it "validates global history settings and rejects non-integer counts" do
      config = Vouch::Configuration::PasswordTrackableConfig.new
      expect { config.history_count = 1.5 }.to raise_error(Vouch::ConfigurationError)
      expect { config.history_window = -10.seconds }.to raise_error(Vouch::ConfigurationError)
      expect { config.history_window = Float::INFINITY }.to raise_error(Vouch::ConfigurationError)
      expect(config.history_count).to eq(5)
    end

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
