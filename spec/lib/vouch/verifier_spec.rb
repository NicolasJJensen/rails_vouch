# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Verifier do
  Reflection = Struct.new(:klass)

  def check(feature, columns:, delivery_owner: nil)
    klass = Class.new
    klass.define_singleton_method(:column_names) { columns.map(&:to_s) }
    method = Vouch::FeatureContracts.delivery_method(feature)
    owner = delivery_owner == :inherited ? Vouch.const_get(feature.to_s.camelize) : klass
    klass.define_singleton_method(:instance_method) { |_name| Struct.new(:owner).new(owner) }
    errors = []
    described_class.new.send(:verify_credential_contract, Reflection.new(klass), feature,
      double(scope_name: :test), errors)
    errors
  end

  it "reports missing schema columns for each credential feature" do
    expect(check(:verifiable, columns: [])).to include(/verification_version/)
    expect(check(:two_factorable, columns: [])).to include(/two_factor_nonce/)
    expect(check(:magic_linkable, columns: [])).to include(/sign_in_nonce/)
  end

  it "rejects inherited delivery defaults" do
    expect(check(:verifiable, columns: Vouch::FeatureContracts.columns(:verifiable), delivery_owner: :inherited)).to include(/deliver_verification_code/)
    expect(check(:two_factorable, columns: Vouch::FeatureContracts.columns(:two_factorable), delivery_owner: :inherited)).to include(/deliver_two_factor_code/)
    expect(check(:magic_linkable, columns: Vouch::FeatureContracts.columns(:magic_linkable), delivery_owner: :inherited)).to include(/deliver_sign_in_code/)
  end

  it "accepts a host delivery override" do
    expect(check(:verifiable, columns: Vouch::FeatureContracts.columns(:verifiable), delivery_owner: :override)).to be_empty
    expect(check(:two_factorable, columns: Vouch::FeatureContracts.columns(:two_factorable), delivery_owner: :override)).to be_empty
    expect(check(:magic_linkable, columns: Vouch::FeatureContracts.columns(:magic_linkable), delivery_owner: :override)).to be_empty
  end

  it "checks password archive columns" do
    archive = Class.new
    archive.define_singleton_method(:column_names) { ["created_at"] }
    account = double(password_archive_reflection: Reflection.new(archive))
    errors = []
    described_class.new.send(:verify_password_archives, account, double(scope_name: :test), errors)
    expect(errors.join).to include("password_digest")
  end

  it "checks backup-code association and columns" do
    backup = Class.new
    backup.define_singleton_method(:column_names) { ["used_at"] }
    credential = Class.new
    credential.define_singleton_method(:reflect_on_association) { |_name| Reflection.new(backup) }
    errors = []
    described_class.new.send(:verify_backup_codes, Reflection.new(credential), double(scope_name: :test), errors)
    expect(errors.join).to include("code_digest")
  end

  it "checks recovery-code table columns" do
    codes = Class.new
    codes.define_singleton_method(:column_names) { ["code_digest"] }
    account = Class.new
    account.define_singleton_method(:reflect_on_association) { |_name| Reflection.new(codes) }
    errors = []
    described_class.new.send(:verify_recovery_codes, account, double(scope_name: :test), errors)
    expect(errors.join).to include("recoverable_type")
  end

  it "checks Verifiable columns on mapped concern-bearing credentials" do
    mapping = Vouch.mapping_for(:user)
    original = TwoFactorCredential.column_names
    allow(TwoFactorCredential).to receive(:column_names).and_return(original - ["verification_nonce"])

    expect { described_class.new([mapping]).verify! }.to raise_error do |error|
      expect(error.message).to include("TwoFactorCredential requires column :verification_nonce")
    end
  end

  it "reports every Verifiable and TwoFactorable runtime column through the public verifier" do
    mapping = Vouch.mapping_for(:user)
    credential = mapping.two_factor_credential_associations.first.klass

    {
      verifiable: credential,
      two_factorable: credential
    }.each do |feature, klass|
      Vouch::FeatureContracts.columns(feature).each do |missing|
        original = klass.column_names
        allow(klass).to receive(:column_names).and_return(original - [missing.to_s])

        expect { described_class.new([mapping]).verify! }.to raise_error do |error|
          expect(error.message).to include("#{klass.name} requires column :#{missing}")
        end

        allow(klass).to receive(:column_names).and_return(original)
      end
    end
  end

  it "checks MagicLinkable columns on an explicitly mapped concern-bearing association" do
    Account.has_many :phone_verifications, class_name: "PhoneVerification", foreign_key: :id
    mapping = Vouch::Mapping.new(:phone, account: "Account", identity: "User",
      associations: { magic_linkable: :phone_verifications })
    mapping.resolve_reflections!
    original = PhoneVerification.column_names
    Vouch::FeatureContracts.columns(:magic_linkable).each do |missing|
      allow(PhoneVerification).to receive(:column_names).and_return(original - [missing.to_s])
      expect { described_class.new([mapping]).verify! }.to raise_error do |error|
        expect(error.message).to include("PhoneVerification requires column :#{missing}")
      end
    end
  ensure
    Account._reflections.delete(:phone_verifications)
  end

  it "accepts method-backed configured Verifiable subjects through the public verifier" do
    credential = Class.new do
      def self.name = "VirtualCredential"
      def self.column_names = Vouch::FeatureContracts.columns(:verifiable).map(&:to_s)
      def self.instance_method(name) = Struct.new(:owner).new(self)
      def self.verifiable_subject_attribute = :virtual_subject
      def virtual_subject = "virtual"
      def deliver_verification_code(_code); end
    end
    account = Class.new do
      def self.name = "VirtualAccount"
      def self.auth_feature_enabled?(_feature) = false
      def self.column_names = []
    end
    identity = Class.new do
      def self.name = "VirtualIdentity"
      def self.column_names = []
      def self.ancestors = []
    end
    mapping = double(scope_name: :virtual, account_class: account, identity_class: identity,
      credential_associations: { verifiable: [Reflection.new(credential)], magic_linkable: [] })
    allow(mapping).to receive(:resolve_reflections!)

    expect { described_class.new([mapping]).verify! }.not_to raise_error
  end

  it "checks invitation columns on an Invitable split identity" do
    mapping = Vouch.mapping_for(:user)
    original = User.column_names
    allow(User).to receive(:column_names).and_return(original - ["invitation_token", "inviter_id"])
    allow(User).to receive(:reflect_on_all_associations).with(:belongs_to).and_return([])

    expect { described_class.new([mapping]).verify! }.to raise_error do |error|
      expect(error.message).to include('User requires column "invitation_token"')
      expect(error.message).to include("User requires belongs_to :inviter")
    end
  end

  it "aggregates independent contract failures" do
    account = Class.new do
      def self.column_names = []
      def self.auth_feature_enabled?(_feature) = false
    end
    identity = Class.new do
      def self.column_names = []
    end
    mapping = double(scope_name: :test, account_class: account, identity_class: identity)
    allow(mapping).to receive(:resolve_reflections!).and_raise(Vouch::ConfigurationError, "missing identity association")
    allow(mapping).to receive(:credential_associations).and_return({})
    expect { described_class.new([mapping]).verify! }.to raise_error do |error|
      expect(error.message).to include("missing identity association")
    end
  end

  it "runs through the Rails task without mutating mappings" do
    require "rake"
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    load Rails.root.join("../../lib/tasks/vouch.rake").to_s
    before = Vouch.mappings.transform_values(&:object_id)
    expect { Rake::Task["vouch:verify"].invoke }.not_to raise_error
    expect(Vouch.mappings.transform_values(&:object_id)).to eq(before)
  ensure
    Rake::Task["vouch:verify"].reenable if Rake::Task.task_defined?("vouch:verify")
  end
end
