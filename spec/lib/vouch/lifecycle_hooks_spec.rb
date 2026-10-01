# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::LifecycleHooks do
  self.use_transactional_tests = false

  let(:controller_class) do
    Class.new do
      include ActiveHooks::Callbacks
      include Vouch::LifecycleHooks
      define_hooks :save, :commit_of_save

      attr_writer :auth_mapping

      def auth_mapping
        @auth_mapping || Vouch.mapping_for(:user)
      end

      def run_save
        run_commit_hooks(:save) { yield if block_given?; true }
      end

      def run_authenticated_save
        run_authentication_hooks(:save) { yield if block_given?; true }
      end

      def persist_authenticated_save(&block)
        run_authentication_hooks(:save) do |env|
          env.abort! unless run_save(&block)
          true
        end
      end
    end
  end

  it "runs ordinary callbacks inside the transaction" do
    calls = []
    controller_class.set_hook(:save, :before, -> { calls << [:before, ActiveRecord::Base.connection.open_transactions] })
    controller_class.set_hook(:save, :after, -> { calls << [:after, ActiveRecord::Base.connection.open_transactions] })

    controller_class.new.run_save

    expect(calls).to all(satisfy { |(_, transactions)| transactions.positive? })
  end

  it "rolls back when a before callback halts" do
    controller_class.set_hook(:save, :before, -> { throw(:abort) })
    account = Account.new(email_address: "after-hook-#{SecureRandom.hex(6)}@example.com",
      password: "password123", password_confirmation: "password123")

    result = controller_class.new.run_save { account.save! }

    expect(result).to be(false)
    expect(account).not_to be_persisted
  ensure
    account&.destroy
  end

  it "rolls back when an around callback does not yield" do
    controller_class.set_hook(:save, :around, ->(_operation) { :cached })
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

  it "reports a commit callback that does not yield as cancelled" do
    controller_class.set_hook(:commit_of_save, :around, ->(_operation) { :cached })

    expect(controller_class.new.run_authenticated_save).to be(false)
  end

  it "does not misreport committed work when an after-commit callback aborts" do
    controller_class.set_hook(:commit_of_save, :after, ->(env) { env.abort! }, with_env: :positional)
    account = Account.new(email_address: "committed-hook-#{SecureRandom.hex(6)}@example.com",
      password: "password123", password_confirmation: "password123")

    expect(controller_class.new.persist_authenticated_save { account.save! }).to be(true)
    expect(account.reload).to be_persisted
  ensure
    account&.destroy
  end

  it "preserves the operation outcome when an outer callback returns false after yielding" do
    controller_class.set_hook(:commit_of_save, :around, ->(operation) { operation.call; false })

    expect(controller_class.new.run_authenticated_save).to be(true)
  end

  it "still propagates unexpected failures after the operation completes" do
    controller_class.set_hook(:commit_of_save, :after, -> { raise "after-commit failure" })

    expect { controller_class.new.run_authenticated_save }.to raise_error("after-commit failure")
  end

  context "with a separate authentication connection" do
    before do
      stub_const("LifecycleAuthRecord", Class.new(ActiveRecord::Base) do
        self.abstract_class = true
      end)
      database = ActiveRecord::Base.connection_db_config.configuration_hash
      LifecycleAuthRecord.connects_to(database: {writing: database, reading: database})

      %w[Account Profile OauthIdentity].each do |name|
        stub_const("LifecycleAuth#{name}", Class.new(LifecycleAuthRecord) do
          self.table_name = "vouch_lifecycle_#{name.underscore.pluralize}"
        end)
      end

      LifecycleAuthRecord.connected_to(role: :writing) do
        LifecycleAuthRecord.with_connection do |connection|
          [LifecycleAuthAccount, LifecycleAuthProfile, LifecycleAuthOauthIdentity].each do |model|
            connection.create_table(model.table_name) { |table| table.string :name, null: false }
          end
        end
      end

      controller.auth_mapping = Struct.new(:account_class).new(LifecycleAuthAccount)
    end

    after do
      LifecycleAuthRecord.connected_to(role: :writing) do
        LifecycleAuthRecord.with_connection do |connection|
          [LifecycleAuthAccount, LifecycleAuthProfile, LifecycleAuthOauthIdentity].reverse_each do |model|
            connection.drop_table(model.table_name, if_exists: true)
          end
        end
      end
      %i[writing reading].each do |role|
        LifecycleAuthRecord.connection_handler.remove_connection_pool(
          LifecycleAuthRecord.connection_specification_name, role: role
        )
      end
    end

    let(:controller) { controller_class.new }

    it "rolls back owner and profile writes when the OAuth write fails" do
      expect(LifecycleAuthAccount.connection_pool).not_to equal(ActiveRecord::Base.connection_pool)

      expect do
        controller.persist_authenticated_save do
          LifecycleAuthAccount.create!(name: "owner")
          LifecycleAuthProfile.create!(name: "profile")
          LifecycleAuthOauthIdentity.create!(name: nil)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)

      expect(LifecycleAuthAccount.count).to eq(0)
      expect(LifecycleAuthProfile.count).to eq(0)
      expect(LifecycleAuthOauthIdentity.count).to eq(0)
    end

    it "rolls back mapped writes when a transactional callback cancels" do
      controller_class.set_hook(:save, :after, -> { raise ActiveRecord::Rollback })

      result = controller.persist_authenticated_save { LifecycleAuthAccount.create!(name: "owner") }

      expect(result).to be(false)
      expect(LifecycleAuthAccount.count).to eq(0)
    end

    it "does not report success when a model cancels immediately before commit" do
      LifecycleAuthAccount.before_commit { raise ActiveRecord::Rollback }

      result = controller.persist_authenticated_save { LifecycleAuthAccount.create!(name: "owner") }

      expect(result).to be(false)
      expect(LifecycleAuthAccount.count).to eq(0)
    end

    it "rejects a transaction on the mapped connection before outer callbacks" do
      calls = []
      controller_class.set_hook(:commit_of_save, :before, -> { calls << :before })

      expect do
        LifecycleAuthAccount.transaction { controller.persist_authenticated_save }
      end.to raise_error(Vouch::ConfigurationError, /existing joinable transaction/)

      expect(calls).to be_empty
    end

    it "does not mistake an unrelated Base transaction for the authentication transaction" do
      result = ActiveRecord::Base.transaction { controller.persist_authenticated_save }

      expect(result).to be(true)
    end

    it "uses the writing connection even when the caller selects the reading role" do
      calls = []
      controller_class.set_hook(:save, :before, -> {
        calls << [LifecycleAuthAccount.current_role, LifecycleAuthAccount.connection.open_transactions]
      })
      controller_class.set_hook(:commit_of_save, :after, -> {
        calls << [LifecycleAuthAccount.current_role, LifecycleAuthAccount.connection.open_transactions]
      })

      LifecycleAuthRecord.connected_to(role: :reading) do
        expect(controller.persist_authenticated_save { LifecycleAuthAccount.create!(name: "owner") }).to be(true)
        expect(LifecycleAuthAccount.current_role).to eq(:reading)
      end

      expect(calls).to eq([[:writing, 1], [:writing, 0]])
      expect(LifecycleAuthAccount.count).to eq(1)
    end

    it "checks the writing transaction even when the caller selects the reading role" do
      expect do
        LifecycleAuthRecord.connected_to(role: :writing) do
          LifecycleAuthAccount.transaction do
            LifecycleAuthRecord.connected_to(role: :reading) { controller.persist_authenticated_save }
          end
        end
      end.to raise_error(Vouch::ConfigurationError, /existing joinable transaction/)
    end
  end
end
