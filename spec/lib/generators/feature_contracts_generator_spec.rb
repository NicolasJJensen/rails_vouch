# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "vouch/feature_contracts"
require "generators/vouch/lockable/lockable_generator"
require "generators/vouch/password_resetable/password_resetable_generator"
require "generators/vouch/recoverable/recoverable_generator"
require "generators/vouch/two_factorable/two_factorable_generator"
require "generators/vouch/verifiable/verifiable_generator"
require "generators/vouch/magic_linkable/magic_linkable_generator"

RSpec.describe "feature generator contracts" do
  GENERATORS = {
    lockable: Vouch::Generators::LockableGenerator,
    password_resetable: Vouch::Generators::PasswordResetableGenerator,
    recoverable: Vouch::Generators::RecoverableGenerator,
    two_factorable: Vouch::Generators::TwoFactorableGenerator,
    verifiable: Vouch::Generators::VerifiableGenerator,
    magic_linkable: Vouch::Generators::MagicLinkableGenerator
  }.freeze

  GENERATORS.each do |feature, generator_class|
    it "generates every #{feature} column required by FeatureContracts" do
      Dir.mktmpdir("vouch-#{feature}-contract") do |directory|
        generator = generator_class.new(["accounts"])
        generator.destination_root = directory
        Dir.chdir(directory) { generator.invoke_all }

        migration = Dir[File.join(directory, "db/migrate/*.rb")].map { |path| File.read(path) }.join
        required_columns = Vouch::FeatureContracts.columns(feature) - [:created_at]
        required_columns.each { |column| expect(migration).to include(":#{column}") }
      end
    end
  end
end
