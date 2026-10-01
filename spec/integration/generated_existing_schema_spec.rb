# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "tmpdir"
require "generators/vouch/password_resetable/password_resetable_generator"
require "generators/vouch/verifiable/verifiable_generator"

RSpec.describe "feature migrations over existing columns" do
  it "executes signed to opaque to signed migrations and revokes earlier state each time" do
    connection = ActiveRecord::Base.connection
    table = "vouch_reset_switch_#{SecureRandom.hex(4)}"
    connection.create_table(table)
    stub_const("ResetSwitchRecord", Class.new(ApplicationRecord) { self.table_name = table })
    Dir.mktmpdir("vouch-reset-switch") do |directory|
      FileUtils.mkdir_p("#{directory}/app/models")
      File.write("#{directory}/app/models/reset_switch_record.rb", "class ResetSwitchRecord < ApplicationRecord\nend\n")
      record = ResetSwitchRecord.create!
      %w[signed opaque signed].each do |strategy|
        previous = Dir["#{directory}/db/migrate/*.rb"]
        generator = Vouch::Generators::PasswordResetableGenerator.new(["ResetSwitchRecord"],
          model_only: true, token_strategy: strategy)
        generator.destination_root = directory
        generator.invoke_all
        source = File.read((Dir["#{directory}/db/migrate/*.rb"] - previous).sole)
        namespace = Module.new
        namespace.module_eval(source)
        namespace.const_get(source[/class (\w+)/, 1]).new.migrate(:up)
        ResetSwitchRecord.reset_column_information
        record.reload
        state_columns = record.attributes.keys.grep(/password_reset/)
        expect(record.attributes.slice(*state_columns).values).to all(be_nil)
        expect(File.read("#{directory}/app/models/reset_switch_record.rb")).to include("token_strategy: :#{strategy}")
        record.update_columns(strategy == "signed" ? {password_reset_nonce: "previous-nonce"} :
          {password_reset_token_digest: "previous-digest", password_reset_sent_at: Time.current})
      end
      expect(connection.index_exists?(table, :password_reset_token_digest, unique: true)).to be(true)
    end
  ensure
    connection.drop_table(table, if_exists: true) if table
  end

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
        options = generator_class == Vouch::Generators::PasswordResetableGenerator ? {model_only: true, token_strategy: "opaque"} : {}
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
        if generator_class == Vouch::Generators::PasswordResetableGenerator
          expect(connection.index_exists?(table, :password_reset_token_digest, unique: true)).to be(true)
        end
      end
    ensure
      connection.drop_table(table, if_exists: true) if table
    end
  end
end
