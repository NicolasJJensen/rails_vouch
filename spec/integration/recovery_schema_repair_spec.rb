# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "tmpdir"
require "generators/vouch/recovery_codes/storage_generator"
require "generators/vouch/password_trackable/password_trackable_generator"

RSpec.describe "recovery storage constraint repair", use_transactional_fixtures: false do
  before do
    @connection = ActiveRecord::Base.connection
    @schema = "vouch_repair_#{Process.pid}"
    @previous = @connection.schema_search_path
    @connection.execute("CREATE SCHEMA #{@schema}")
    @connection.schema_search_path = @schema
    @connection.create_table(:repair_owners)
    @connection.create_table(:repair_owner_recovery_codes) do |t|
      t.bigint :repair_owner_id
      t.string :code_digest
      t.datetime :used_at
    end
    stub_const("RepairOwner", Class.new(ApplicationRecord) { self.table_name = "repair_owners" })
    @directory = Dir.mktmpdir("vouch-recovery-repair")
    FileUtils.mkdir_p("#{@directory}/app/models")
    File.write("#{@directory}/app/models/repair_owner.rb", "class RepairOwner < ApplicationRecord\nend\n")
  end

  after do
    @connection.schema_search_path = @previous
    @connection.execute("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
    FileUtils.rm_rf(@directory)
  end

  def generator
    instance = Vouch::Generators::RecoveryCodeStorageGenerator.new(["RepairOwner"])
    instance.destination_root = @directory
    allow(instance).to receive(:generating_current_host?).and_return(true)
    instance
  end

  it "repairs missing null constraints, indexes and concrete foreign keys without recreating storage" do
    generator.invoke_all
    migrations = Dir["#{@directory}/db/migrate/*.rb"]
    expect(migrations.length).to eq(1)
    source = File.read(migrations.sole)
    expect(source).not_to include("create_table")
    namespace = Module.new
    namespace.module_eval(source)
    namespace.const_get(source[/class (\w+)/, 1]).new.migrate(:up)
    columns = @connection.columns(:repair_owner_recovery_codes).index_by(&:name)
    expect(columns.fetch("repair_owner_id").null).to be(false)
    expect(columns.fetch("code_digest").null).to be(false)
    expect(@connection.index_exists?(:repair_owner_recovery_codes, :repair_owner_id)).to be(true)
    expect(@connection.index_exists?(:repair_owner_recovery_codes, :used_at)).to be(true)
    expect(@connection.foreign_keys(:repair_owner_recovery_codes).sole.to_table).to eq("repair_owners")
    generator.invoke_all
    expect(Dir["#{@directory}/db/migrate/*.rb"]).to eq(migrations)
  end

  it "keeps distinct later repairs for the same table" do
    first = generator
    first.send(:repair_schema_constraints, "repair_owner_recovery_codes", required: ["code_digest"], indexes: [])
    second = generator
    second.send(:repair_schema_constraints, "repair_owner_recovery_codes", required: ["repair_owner_id"], indexes: ["used_at"])
    second.send(:repair_schema_constraints, "repair_owner_recovery_codes", required: ["repair_owner_id"], indexes: ["used_at"])
    expect(Dir["#{@directory}/db/migrate/*.rb"].length).to eq(2)
  end

  it "ignores commented and quoted constraints when repairing pending storage" do
    @connection.drop_table(:repair_owner_recovery_codes)
    FileUtils.mkdir_p("#{@directory}/db/migrate")
    File.write("#{@directory}/db/migrate/20260101000000_codes.rb", <<~SOURCE)
      class Codes < ActiveRecord::Migration[8.1]
        def change
          create_table :repair_owner_recovery_codes do |t|
            t.bigint :repair_owner_id # null: false
            t.string :code_digest # null: false
            t.datetime :used_at
            # t.index :used_at
            # t.foreign_key :repair_owners
            example = "t.index :repair_owner_id"
          end
        end
      end
    SOURCE
    generator.invoke_all
    source = File.read(Dir["#{@directory}/db/migrate/*repair*rb"].sole)
    expect(source).to include("change_column_null", "add_index", "add_foreign_key")
  end

  it "repairs a compatible password archive table without recreating it" do
    @connection.create_table(:password_archives) do |t|
      t.bigint :repair_owner_id
      t.string :password_digest
      t.datetime :created_at
      t.bigint :auditor_id
    end
    @connection.create_table(:auditors)
    @connection.add_foreign_key :password_archives, :auditors
    instance = Vouch::Generators::PasswordTrackableGenerator.new(["RepairOwner"])
    instance.destination_root = @directory
    allow(instance).to receive(:generating_current_host?).and_return(true)
    instance.invoke_all
    source = File.read(Dir["#{@directory}/db/migrate/*.rb"].sole)
    namespace = Module.new
    namespace.module_eval(source)
    namespace.const_get(source[/class (\w+)/, 1]).new.migrate(:up)
    expect(@connection.columns(:password_archives).reject { |column| %w[id auditor_id].include?(column.name) }.map(&:null)).to eq([false, false, false])
    expect(@connection.index_exists?(:password_archives, %w[repair_owner_id created_at])).to be(true)
    expect(@connection.foreign_keys(:password_archives).map(&:to_table)).to contain_exactly("repair_owners", "auditors")
  end

  it "rejects ownership pointing at another table before writing files" do
    @connection.create_table(:wrong_owners)
    @connection.add_foreign_key :repair_owner_recovery_codes, :wrong_owners, column: :repair_owner_id
    expect { generator.invoke_all }.to raise_error(Thor::Error, /incompatible recovery ownership/)
    expect(Dir["#{@directory}/db/migrate/*.rb"]).to be_empty
    expect(File).not_to exist("#{@directory}/app/models/repair_owner_recovery_code.rb")
  end
end
