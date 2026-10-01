require "rails_helper"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "generators/vouch/omniauth/omniauth_generator"

RSpec.describe "OAuth storage generation", use_transactional_fixtures: false do
  around do |example|
    connection = ActiveRecord::Base.connection
    original = connection.schema_search_path
    schema = "oauth_storage_#{Process.pid}_#{SecureRandom.hex(4)}"
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = schema
    connection.create_table(:schema_migrations, id: false) { |table| table.string :version, primary_key: true }
    Dir.mktmpdir("vouch-oauth-storage") do |directory|
      @directory = directory
      example.run
    end
  ensure
    connection.schema_search_path = original
    connection.execute("DROP SCHEMA #{schema} CASCADE")
    connection.schema_cache.clear!
  end

  before do
    ActiveRecord::Base.connection.create_table(:storage_owners)
    stub_const("StorageOwner", Class.new(ApplicationRecord) { self.table_name = "storage_owners" })
  end

  def generator
    Vouch::Generators::OmniauthGenerator.new(["StorageOwner"], {model_only: true}, destination_root: @directory).tap do |instance|
      allow(instance).to receive(:generating_current_host?).and_return(true)
    end
  end

  def create_storage(null: true, unique: false, foreign: nil)
    ActiveRecord::Base.connection.create_table(:oauth_identities) do |table|
      table.bigint :storage_owner_id, null: null
      table.string :provider, null: null
      table.string :uid, null: null
      table.json :auth_data
      table.index [:provider, :uid], unique: unique
      table.foreign_key foreign, column: :storage_owner_id if foreign
    end
  end

  def migrate
    ActiveRecord::MigrationContext.new(File.join(@directory, "db/migrate")).migrate
  end

  def expect_constraints
    connection = ActiveRecord::Base.connection
    expect(connection.columns(:oauth_identities).select { |column| %w[storage_owner_id provider uid].include?(column.name) }.map(&:null)).to eq([false, false, false])
    expect(connection.index_exists?(:oauth_identities, [:provider, :uid], unique: true)).to be(true)
    expect(connection.foreign_key_exists?(:oauth_identities, :storage_owners, column: :storage_owner_id)).to be(true)
  end

  it "repairs live constraints and is repeatable before and after migration" do
    create_storage
    generator.create_feature_migration
    files = Dir[File.join(@directory, "db/migrate/*.rb")]
    expect(files.length).to eq(1)
    generator.create_feature_migration
    expect(Dir[File.join(@directory, "db/migrate/*.rb")]).to eq(files)
    migrate
    expect_constraints
    generator.create_feature_migration
    expect(Dir[File.join(@directory, "db/migrate/*.rb")]).to eq(files)
  end

  it "does not treat a partial provider index as global identity uniqueness" do
    create_storage(null: false, foreign: :storage_owners)
    connection = ActiveRecord::Base.connection
    connection.add_index :oauth_identities, [:provider, :uid], unique: true,
      where: "provider = 'github'", name: "only_github_unique"
    generator.create_feature_migration
    migrate
    expect_constraints
    expect(connection.indexes(:oauth_identities).any? { |index| index.name == "only_github_unique" }).to be(true)
  end

  it "rejects a live foreign key to another owner rather than adding conflicting ownership" do
    ActiveRecord::Base.connection.create_table(:other_owners)
    create_storage(foreign: :other_owners)
    expect { generator.create_feature_migration }.to raise_error(Thor::Error, /owner foreign key/)
    expect(Dir[File.join(@directory, "db/migrate/*.rb")]).to be_empty
  end

  it "repairs a complete pending table without rewriting its source" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    file = File.join(@directory, "db/migrate/20260101000000_create_oauth_identities.rb")
    source = <<~SOURCE
      class CreateOauthIdentities < ActiveRecord::Migration[8.1]
        def change
          create_table :oauth_identities do |t|
            t.bigint :storage_owner_id
            t.string :provider
            t.string :uid
            t.json :auth_data
          end
        end
      end
    SOURCE
    File.write(file, source)
    generator.create_feature_migration
    generator.create_feature_migration
    expect(File.read(file)).to eq(source)
    expect(Dir[File.join(@directory, "db/migrate/*.rb")].length).to eq(2)
    migrate
    expect_constraints
  end

  it "does not mistake another association's foreign key for the owner foreign key" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    File.write(File.join(@directory, "db/migrate/20260101000000_create_oauth_identities.rb"), <<~SOURCE)
      class CreateOauthIdentities < ActiveRecord::Migration[8.1]
        def change
          create_table :oauth_identities do |t|
            t.bigint :storage_owner_id, null: false
            t.references :other, foreign_key: { to_table: :storage_owners }
            t.string :provider, null: false
            t.string :uid, null: false
            t.json :auth_data
            t.index [:provider, :uid], unique: true
          end
        end
      end
    SOURCE
    generator.create_feature_migration
    expect(Dir[File.join(@directory, "db/migrate/*repair*.rb")].length).to eq(1)
    migrate
    expect_constraints
  end

  it "repairs a missing owner index when every other pending constraint is present" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    File.write(File.join(@directory, "db/migrate/20260101000000_create_oauth_identities.rb"), <<~SOURCE)
      class CreateOauthIdentities < ActiveRecord::Migration[8.1]
        def change
          create_table :oauth_identities do |t|
            t.bigint :storage_owner_id, null: false
            t.string :provider, null: false
            t.string :uid, null: false
            t.json :auth_data
            t.index [:provider, :uid], unique: true
            t.foreign_key :storage_owners, column: :storage_owner_id
          end
        end
      end
    SOURCE
    generator.create_feature_migration
    expect(Dir[File.join(@directory, "db/migrate/*repair*.rb")].length).to eq(1)
    migrate
    expect_constraints
    expect(ActiveRecord::Base.connection.index_exists?(:oauth_identities, :storage_owner_id)).to be(true)
  end

  it "rejects pending references to an incorrect primary key on the correct owner table" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    path = File.join(@directory, "db/migrate/20260101000000_create_oauth_identities.rb")
    ["t.references :storage_owner, null: false, foreign_key: { to_table: :storage_owners, primary_key: :external_id }",
      "t.bigint :storage_owner_id, null: false; t.foreign_key :storage_owners, column: :storage_owner_id, primary_key: :external_id"].each do |owner_declaration|
      File.write(path, <<~SOURCE)
        class CreateOauthIdentities < ActiveRecord::Migration[8.1]
          def change
            create_table :oauth_identities do |t|
              #{owner_declaration}
              t.string :provider, null: false
              t.string :uid, null: false
              t.json :auth_data
              t.index [:provider, :uid], unique: true
            end
          end
        end
      SOURCE
      expect { generator.create_feature_migration }.to raise_error(Thor::Error, /owner foreign key/)
      expect(Dir[File.join(@directory, "db/migrate/*repair*.rb")]).to be_empty
    end
  end

  it "does not count DSL examples inside migration strings as columns" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    File.write(File.join(@directory, "db/migrate/20260101000000_create_oauth_identities.rb"), <<~SOURCE)
      class CreateOauthIdentities < ActiveRecord::Migration[8.1]
        def change
          create_table :oauth_identities do |t|
            t.string :provider
            example = "t.string :uid; t.json :auth_data; t.bigint :storage_owner_id"
          end
        end
      end
    SOURCE
    expect { generator.create_feature_migration }.to raise_error(Thor::Error, /incomplete/)
    expect(Dir[File.join(@directory, "db/migrate/*repair*.rb")]).to be_empty
  end

  it "rejects incomplete pending columns before writing any additional artifacts" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    file = File.join(@directory, "db/migrate/20260101000000_create_oauth_identities.rb")
    File.write(file, "class CreateOauthIdentities < ActiveRecord::Migration[8.1]\n  def change\n    create_table :oauth_identities do |t|\n      t.string :provider\n    end\n  end\nend\n")
    expect { generator.invoke_all }.to raise_error(Thor::Error, /incomplete/)
    expect(Dir[File.join(@directory, "db/migrate/*.rb")]).to eq([file])
    expect(File).not_to exist(File.join(@directory, "app/models/oauth_identity.rb"))
  end
end
