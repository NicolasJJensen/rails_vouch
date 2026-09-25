# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "rails/generators"
require "tmpdir"

require "generators/vouch/omniauth/omniauth_generator"
require "generators/vouch/password_trackable/password_trackable_generator"
require "generators/vouch/backup_codes/backup_codes_generator"
require "generators/vouch/invitations/invitations_generator"
require "generators/vouch/scope/scope_generator"

RSpec.describe "generated custom primary key migrations", :generated_host do
  around do |example|
    connection = ActiveRecord::Base.connection
    ddl_connection = PG.connect(dbname: connection.pool.db_config.database)
    schema = "vouch_generated_keys_#{Process.pid}_#{rand(100_000)}"
    previous_search_path = connection.schema_search_path

    ddl_connection.exec("CREATE SCHEMA \"#{schema}\"")
    ddl_connection.exec(<<~SQL)
      CREATE TABLE "#{schema}"."schema_migrations" (
        "version" character varying NOT NULL PRIMARY KEY
      )
    SQL
    ddl_connection.exec(<<~SQL)
      CREATE TABLE "#{schema}"."ar_internal_metadata" (
        "key" character varying NOT NULL PRIMARY KEY,
        "value" character varying,
        "created_at" timestamp(6) NOT NULL,
        "updated_at" timestamp(6) NOT NULL
      )
    SQL
    connection.schema_search_path = schema

    example.run
  ensure
    connection.rollback_transaction while connection.open_transactions.positive?
    connection.schema_search_path = previous_search_path
    ddl_connection.exec("SET lock_timeout = '5s'")
    ddl_connection.exec("DROP SCHEMA IF EXISTS \"#{schema}\" CASCADE")
    connection.schema_cache.clear!
    ddl_connection.close
  end

  it "runs UUID migrations for a scalar user_number primary key", use_transactional_fixtures: false do
    exercise_generated_keys(
      key_columns: {user_number: :uuid},
      key_values: {user_number: SecureRandom.uuid},
      primary_key: "user_number"
    )
  end

  it "runs string migrations for a custom key", use_transactional_fixtures: false do
    exercise_generated_keys(
      key_columns: {user_number: :string},
      key_values: {user_number: "user-#{SecureRandom.hex(6)}"},
      primary_key: "user_number"
    )
  end

  it "runs composite migrations for organisation_id and user_number keys", use_transactional_fixtures: false do
    exercise_generated_keys(
      key_columns: {organisation_id: :bigint, user_number: :string},
      key_values: {organisation_id: 7, user_number: "user-#{SecureRandom.hex(6)}"},
      primary_key: %w[organisation_id user_number]
    )
  end

  private

  def exercise_generated_keys(key_columns:, key_values:, primary_key:)
    skip "custom primary key integration requires PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    suffix = "#{Process.pid}#{rand(100_000)}"
    owner_name = "GeneratedKeyOwner#{suffix}"
    identity_name = "GeneratedKeyIdentity#{suffix}"
    owner_table = "generated_key_owners_#{suffix}"
    directory = Dir.mktmpdir("vouch-generated-primary-keys")
    original_oauth_identity = Object.const_get(:OauthIdentity, false) if Object.const_defined?(:OauthIdentity, false)
    original_password_archive = Object.const_get(:PasswordArchive, false) if Object.const_defined?(:PasswordArchive, false)
    owner_class = Class.new(ApplicationRecord) do
      self.table_name = owner_table
      self.primary_key = primary_key
    end
    stub_const(owner_name, owner_class)

    create_owner_table(owner_table, key_columns, primary_key)
    owner_class.reset_column_information
    write_owner_model(directory, owner_name, owner_table, primary_key)

    scope = Vouch::Generators::ScopeGenerator.new(
      ["generated_key_members_#{suffix}", "#{owner_name}:account", "#{identity_name}:identity"]
    )
    scope.destination_root = directory
    Dir.chdir(directory) { scope.invoke_all }

    omniauth = Vouch::Generators::OmniauthGenerator.new([owner_name], model_only: true)
    omniauth.destination_root = directory
    Dir.chdir(directory) { omniauth.invoke_all }

    password_trackable = Vouch::Generators::PasswordTrackableGenerator.new([owner_name])
    password_trackable.destination_root = directory
    Dir.chdir(directory) { password_trackable.invoke_all }

    backup_codes = Vouch::Generators::BackupCodesGenerator.new([owner_name])
    backup_codes.destination_root = directory
    Dir.chdir(directory) { backup_codes.invoke_all }

    invitations = Vouch::Generators::InvitationsGenerator.new(
      [owner_name],
      single_model: true,
      model_only: true
    )
    invitations.destination_root = directory
    Dir.chdir(directory) { invitations.invoke_all }

    migrations_directory = File.join(directory, "db/migrate")
    migration_paths = Dir.children(migrations_directory).sort.map { |name| File.join(migrations_directory, name) }
    expect(migration_paths.length).to eq(7)
    oauth_migration = migration_paths.find { |path| path.end_with?("_create_oauth_identities.rb") }
    password_migration = migration_paths.find { |path| path.end_with?("_create_password_archives.rb") }
    backup_migration = migration_paths.find { |path| path.end_with?("_create_#{owner_table.singularize}_backup_codes.rb") }
    invitation_migration = migration_paths.find { |path| path.end_with?("_add_invitations_to_#{owner_table}.rb") }
    expect([oauth_migration, password_migration, backup_migration, invitation_migration]).to all(be_present)

    [*migration_paths].each do |path|
      expect(RubyVM::InstructionSequence.compile(File.read(path))).to be_a(RubyVM::InstructionSequence)
    end
    expect(File.read(oauth_migration)).to include("add_foreign_key")
    expect(File.read(password_migration)).to include("add_foreign_key")

    ActiveRecord::MigrationContext.new(File.join(directory, "db/migrate")).migrate

    Object.send(:remove_const, :OauthIdentity) if original_oauth_identity
    Object.send(:remove_const, :PasswordArchive) if original_password_archive
    owner_source = File.read(File.join(directory, Vouch::ModelMetadata.new(owner_name).model_path))
    owner_class.class_eval(owner_source.sub(/\Aclass [^\n]+\n/, "").sub(/\nend\s*\z/, ""))
    load File.join(directory, "app/models/oauth_identity.rb")
    load File.join(directory, "app/models/password_archive.rb")
    load File.join(directory, Vouch::ModelMetadata.new(identity_name).model_path)
    load File.join(directory, "app/models/#{Vouch::ModelMetadata.new(owner_name).class_name.underscore}_backup_code.rb")
    owner_class.reset_column_information

    owner = owner_class.create!(**key_values)
    owner_association = Vouch::ModelMetadata.new(owner_name).association_key
    owner_metadata = Vouch::ModelMetadata.new(owner_name)
    identity_class = Object.const_get(identity_name)
    identity_reflection = identity_class.reflect_on_association(owner_association)
    expect(Array(identity_reflection.foreign_key).map(&:to_s)).to eq(owner_metadata.foreign_keys)
    expect(Array(identity_reflection.options[:primary_key]).map(&:to_s)).to eq(owner_metadata.primary_keys)
    identity = identity_class.create!(owner_association.to_sym => owner)
    expect(identity.public_send(owner_association)).to eq(owner)
    expect(owner.public_send(Vouch::ModelMetadata.new(identity_name).association_key.pluralize)).to include(identity)

    oauth = OauthIdentity.create!(owner_association.to_sym => owner, provider: "github", uid: "uid-#{suffix}")
    oauth_reflection = OauthIdentity.reflect_on_association(owner_association)
    expect(Array(oauth_reflection.foreign_key).map(&:to_s)).to eq(owner_metadata.foreign_keys)
    expect(Array(oauth_reflection.options[:primary_key]).map(&:to_s)).to eq(owner_metadata.primary_keys)
    expect(oauth.public_send(owner_association)).to eq(owner)
    expect(owner.oauth_identities).to include(oauth)

    archive = PasswordArchive.create!(account: owner, password_digest: "digest")
    archive_reflection = PasswordArchive.reflect_on_association(:account)
    expect(Array(archive_reflection.foreign_key).map(&:to_s)).to eq(owner_metadata.foreign_keys("account"))
    expect(Array(archive_reflection.options[:primary_key]).map(&:to_s)).to eq(owner_metadata.primary_keys)
    expect(archive.account).to eq(owner)
    expect(owner.password_archives).to include(archive)

    backup_code_class = Object.const_get("#{owner_name}BackupCode")
    backup_reflection = backup_code_class.reflect_on_association(owner_association)
    expect(Array(backup_reflection.foreign_key).map(&:to_s)).to eq(owner_metadata.foreign_keys(owner_association))
    expect(Array(backup_reflection.options[:primary_key]).map(&:to_s)).to eq(owner_metadata.primary_keys)
    backup_code = backup_code_class.create!(owner_association.to_sym => owner, code_digest: "digest")
    expect(backup_code.public_send(owner_association)).to eq(owner)
    expect(owner.backup_codes).to include(backup_code)

    invitee_keys = key_values.merge(
      user_number: key_columns.fetch(:user_number) == :uuid ? SecureRandom.uuid : "invitee-#{SecureRandom.hex(6)}"
    )
    inviter_reflection = owner_class.reflect_on_association(:inviter)
    expect(Array(inviter_reflection.foreign_key).map(&:to_s)).to eq(owner_metadata.foreign_keys("inviter"))
    expect(Array(inviter_reflection.options[:primary_key]).map(&:to_s)).to eq(owner_metadata.primary_keys)
    invitee = owner_class.invite!(invited_by: owner, **invitee_keys).value
    expect(invitee.inviter).to eq(owner)
    expect(owner.invitees).to include(invitee)

    expect(ActiveRecord::Base.connection.foreign_keys("oauth_identities").map(&:to_table)).to include(owner_table)
    expect(ActiveRecord::Base.connection.foreign_keys("password_archives").map(&:to_table)).to include(owner_table)
    expect(ActiveRecord::Base.connection.foreign_keys(owner_table).map(&:to_table)).to include(owner_table)
    expect(ActiveRecord::Base.connection.foreign_keys(backup_code_class.table_name).map(&:to_table)).to include(owner_table)
  ensure
    if Object.const_defined?(:OauthIdentity, false) && Object.const_get(:OauthIdentity, false) != original_oauth_identity
      Object.send(:remove_const, :OauthIdentity)
    end
    if Object.const_defined?(:PasswordArchive, false) && Object.const_get(:PasswordArchive, false) != original_password_archive
      Object.send(:remove_const, :PasswordArchive)
    end
    Object.const_set(:OauthIdentity, original_oauth_identity) if original_oauth_identity && !Object.const_defined?(:OauthIdentity, false)
    Object.const_set(:PasswordArchive, original_password_archive) if original_password_archive && !Object.const_defined?(:PasswordArchive, false)
    Object.send(:remove_const, identity_name) if identity_name && Object.const_defined?(identity_name, false)
    FileUtils.rm_rf(directory) if directory
  end

  def create_owner_table(table, key_columns, primary_key)
    connection = ActiveRecord::Base.connection
    connection.create_table(table, id: false) do |t|
      key_columns.each { |name, type| t.public_send(type, name, null: false) }
      t.string :email_address
      t.string :password_digest
    end
    keys = Array(primary_key).map { |key| connection.quote_column_name(key) }.join(", ")
    connection.execute("ALTER TABLE #{connection.quote_table_name(table)} ADD PRIMARY KEY (#{keys})")
  end

  def write_owner_model(directory, owner_name, owner_table, primary_key)
    source = <<~RUBY
      class #{owner_name} < ApplicationRecord
        self.table_name = #{owner_table.inspect}
        self.primary_key = #{primary_key.inspect}
      end
    RUBY
    path = File.join(directory, Vouch::ModelMetadata.new(owner_name).model_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end
end
