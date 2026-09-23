# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "tmpdir"
require "generators/vouch/password_resetable/password_resetable_generator"
require "generators/vouch/verifiable/verifiable_generator"

RSpec.describe "feature migrations over existing columns" do
  [Vouch::Generators::PasswordResetableGenerator, Vouch::Generators::VerifiableGenerator].each do |generator_class|
    it "preserves existing schema when applying #{generator_class.name.demodulize}" do
      connection = ActiveRecord::Base.connection
      table = "vouch_existing_feature_#{SecureRandom.hex(4)}"
      connection.create_table(table) do |t|
        t.string :password_reset_token_digest
        t.string :verification_nonce
      end
      record = Class.new(ApplicationRecord) { self.table_name = table }
      stub_const("ExistingFeatureRecord", record)
      Dir.mktmpdir("vouch-existing-feature") do |directory|
        options = generator_class == Vouch::Generators::PasswordResetableGenerator ? {model_only: true} : {}
        generator = generator_class.new(["ExistingFeatureRecord"], options)
        generator.destination_root = directory
        generator.invoke_all
        source = File.read(Dir["#{directory}/db/migrate/*.rb"].sole)
        namespace = Module.new
        namespace.module_eval(source)
        migration = namespace.const_get(source[/class (\w+)/, 1]).new
        2.times { migration.migrate(:up) }
        columns = connection.columns(table).map(&:name)
        expect(columns.count("password_reset_token_digest")).to eq(1)
        expect(columns.count("verification_nonce")).to eq(1)
        expected = generator_class == Vouch::Generators::PasswordResetableGenerator ? "password_reset_sent_at" : "verification_version"
        expect(columns).to include(expected)
      end
    ensure
      connection.drop_table(table, if_exists: true) if table
    end
  end
end
