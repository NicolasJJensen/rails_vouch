# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "generators/vouch/password_trackable/password_trackable_generator"

RSpec.describe "unloaded generator model metadata", use_transactional_fixtures: false do
  it "generates and migrates concrete references to an existing composite-key table" do
    connection = ActiveRecord::Base.connection
    schema = "vouch_metadata_#{Process.pid}"
    original = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = schema
    connection.create_table(:legacy_memberships, id: false, primary_key: %i[region sequence]) do |table|
      table.string :region, null: false
      table.integer :sequence, null: false
      table.string :password_digest
    end
    connection.execute("ALTER TABLE legacy_memberships ADD PRIMARY KEY (region, sequence)") unless connection.primary_keys(:legacy_memberships).present?

    Dir.mktmpdir("vouch-metadata-host") do |directory|
      FileUtils.mkdir_p(File.join(directory, "app/models"))
      File.write(File.join(directory, "app/models/metadata_membership.rb"), <<~SOURCE)
        class MetadataMembership < ApplicationRecord
          self.table_name = "legacy_memberships"
          self.primary_key = [:region, :sequence]
        end
      SOURCE
      generator = Vouch::Generators::PasswordTrackableGenerator.new(["MetadataMembership"])
      generator.destination_root = directory
      generator.invoke_all
      migration = Dir[File.join(directory, "db/migrate/*.rb")].fetch(0)
      load migration
      CreatePasswordArchives.new.migrate(:up)
      columns = connection.columns(:password_archives).index_by(&:name)
      expect(columns.fetch("metadata_membership_region").type).to eq(:string)
      expect(columns.fetch("metadata_membership_sequence").type).to eq(:integer)
      foreign_key = connection.foreign_keys(:password_archives).fetch(0)
      expect(foreign_key.to_table).to eq("legacy_memberships")
      expect(foreign_key.primary_key).to eq(%w[region sequence])
      expect(Object.const_defined?(:MetadataMembership, false)).to be(false)
    end
  ensure
    connection.schema_search_path = original if original
    connection.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE") if schema
    Object.send(:remove_const, :CreatePasswordArchives) if Object.const_defined?(:CreatePasswordArchives, false)
  end
end
