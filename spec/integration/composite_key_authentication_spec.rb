# frozen_string_literal: true

require "rails_helper"
require "pg"

RSpec.describe "composite-key authentication runtime", type: :model do
  around do |example|
    skip "composite-key authentication integration requires PostgreSQL" unless
      ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    connection = ActiveRecord::Base.connection
    ddl_connection = PG.connect(dbname: connection.pool.db_config.database)
    schema = "vouch_cpk_auth_#{Process.pid}_#{rand(100_000)}"
    previous_search_path = connection.schema_search_path

    ddl_connection.exec("CREATE SCHEMA #{quote_identifier(schema)}")
    ddl_connection.exec(<<~SQL)
      CREATE TABLE #{quote_identifier(schema)}."schema_migrations" (
        "version" character varying NOT NULL PRIMARY KEY
      )
    SQL
    ddl_connection.exec(<<~SQL)
      CREATE TABLE #{quote_identifier(schema)}."ar_internal_metadata" (
        "key" character varying NOT NULL PRIMARY KEY,
        "value" character varying,
        "created_at" timestamp(6) NOT NULL,
        "updated_at" timestamp(6) NOT NULL
      )
    SQL
    connection.schema_search_path = schema

    example.run
  ensure
    if connection
      connection.rollback_transaction while connection.open_transactions.positive?
      connection.schema_search_path = previous_search_path
    end
    ddl_connection&.exec("DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")
    connection&.schema_cache&.clear!
    ddl_connection&.close
  end

  it "round-trips a scoped composite identity through Warden and rejects a linked-parent mismatch", use_transactional_fixtures: false do
    suffix = unique_suffix
    account_table = "cpk_accounts_#{suffix}"
    identity_table = "cpk_identities_#{suffix}"
    create_composite_table(account_table, [[:tenant_id, :string], [:local_id, :integer]],
      extra: [[:password_digest, :string]])
    create_composite_table(identity_table, [[:tenant_id, :string], [:local_id, :integer]],
      extra: [[:account_tenant_id, :string], [:account_local_id, :integer]])

    account_name = "CpkWardenAccount#{suffix}"
    identity_name = "CpkWardenIdentity#{suffix}"
    account_class = Class.new(ApplicationRecord) do
      self.table_name = account_table
      self.primary_key = %w[tenant_id local_id]
    end
    identity_class = Class.new(ApplicationRecord) do
      self.table_name = identity_table
      self.primary_key = %w[tenant_id local_id]

      define_method(:account) do
        account_class.find_by(tenant_id: account_tenant_id, local_id: account_local_id)
      end
    end
    stub_const(account_name, account_class)
    stub_const(identity_name, identity_class)
    account_class.reset_column_information
    identity_class.reset_column_information

    first_account = account_class.create!(tenant_id: "north", local_id: 7, password_digest: "x" * 32)
    other_account = account_class.create!(tenant_id: "south", local_id: 7, password_digest: "y" * 32)
    identity = identity_class.create!(tenant_id: "north", local_id: 12,
      account_tenant_id: first_account.tenant_id, account_local_id: first_account.local_id)

    mapping = double(
      scope_name: :cpk_warden_membership,
      membership_scope?: true,
      tenant?: false,
      parent_scope_name: :cpk_warden_account,
      identity_class: identity_class
    )
    allow(mapping).to receive(:account_for) { |record| record.account }
    Vouch::RouteBuilder.new(ActionDispatch::Routing::RouteSet.new)
      .send(:register_warden_scope, mapping)

    serializer = Warden::SessionSerializer.new(
      "warden" => instance_double(Warden::Proxy, user: first_account, raw_session: {})
    )
    payload = serializer.cpk_warden_membership_serialize(identity)
    expect(payload.first).to eq(Vouch::RecordKey.value(identity))
    expect(serializer.cpk_warden_membership_deserialize(payload)).to eq(identity)

    mismatched = Warden::SessionSerializer.new(
      "warden" => instance_double(Warden::Proxy, user: other_account, raw_session: {})
    )
    expect(mismatched.cpk_warden_membership_deserialize(payload)).to be_nil

    operator = identity_class.create!(tenant_id: "south", local_id: 12,
      account_tenant_id: other_account.tenant_id, account_local_id: other_account.local_id)
    allow(mapping).to receive_messages(split_model?: true, evidence_scope_name: :cpk_warden_account)
    allow(Vouch).to receive(:mapping_for).with(:cpk_warden_membership).and_return(mapping)
    allow(Vouch).to receive(:mapping_for).with("cpk_warden_membership").and_return(mapping)
    allow(Vouch).to receive(:each_mapping) do |&block|
      block ? [mapping].each(&block) : [mapping].each
    end
    session = {}
    users = {cpk_warden_membership: operator, cpk_warden_account: other_account}
    proxy = instance_double(Warden::Proxy, raw_session: session)
    allow(proxy).to receive(:user) { |scope| users[scope] }
    allow(proxy).to receive(:set_user) { |record, scope:, **| users[scope] = record }
    allow(proxy).to receive(:logout) { |*scopes| scopes.each { |scope| users.delete(scope) } }
    Vouch::ImpersonationStack.start!(warden: proxy, session: session, source_mapping: mapping,
      target_mapping: mapping, target: identity)
    session.replace(JSON.parse(JSON.generate(session)))
    expect(Vouch::ImpersonationStack.authorized_identity(session, scope: :cpk_warden_membership)).to eq(identity)
    expect(Vouch::ImpersonationStack.original(warden: proxy, session: session, scope: :cpk_warden_membership)).to eq(operator)
    identity.update!(account_tenant_id: other_account.tenant_id, account_local_id: other_account.local_id)
    expect(Vouch::ImpersonationStack.authorized_identity(session, scope: :cpk_warden_membership)).to be_nil
  end

  it "uses the complete composite key for signed tokens and credential lookup", use_transactional_fixtures: false do
    suffix = unique_suffix
    token_table = "cpk_tokens_#{suffix}"
    credential_table = "cpk_credentials_#{suffix}"
    create_composite_table(token_table, [[:tenant_id, :string], [:local_id, :integer]],
      extra: [[:confirmation_nonce, :string], [:verified_at, :datetime], [:created_at, :datetime], [:updated_at, :datetime]])
    create_composite_table(credential_table, [[:tenant_id, :string], [:local_id, :integer]],
      extra: [[:owner_tenant_id, :string], [:owner_local_id, :integer], [:two_factor_enabled_at, :datetime]])

    token_name = "CpkSignedToken#{suffix}"
    credential_name = "CpkCredential#{suffix}"
    token_class = Class.new(ApplicationRecord) do
      self.table_name = token_table
      self.primary_key = %w[tenant_id local_id]
      include Vouch::TokenVerifiable::Concern
      self.token_purpose = "vouch/cpk_signed_token_#{suffix}"
    end
    credential_class = Class.new(ApplicationRecord) do
      self.table_name = credential_table
      self.primary_key = %w[tenant_id local_id]
    end
    stub_const(token_name, token_class)
    stub_const(credential_name, credential_class)
    token_class.reset_column_information
    credential_class.reset_column_information

    first = token_class.create!(tenant_id: "north", local_id: 4)
    second = token_class.create!(tenant_id: "south", local_id: 4)
    first_token = first.confirmation_token
    second_token = second.confirmation_token

    expect(token_class.consume_token(first_token).value).to eq(first)
    expect(token_class.consume_token(second_token).value).to eq(second)

    account = Struct.new(:tenant_id, :local_id).new("north", 9)
    account.define_singleton_method(:credentials) do
      credential_class.where(owner_tenant_id: tenant_id, owner_local_id: local_id)
    end
    association = Struct.new(:name, :klass).new(:credentials, credential_class)
    first_credential = credential_class.create!(tenant_id: "north", local_id: 4,
      owner_tenant_id: "north", owner_local_id: 9)
    credential_class.create!(tenant_id: "south", local_id: 4,
      owner_tenant_id: "south", owner_local_id: 9)

    credentials = Vouch::CredentialSet.new(account, [association])
    expect(credentials.find(Vouch::RecordKey.to_param(first_credential))).to eq(first_credential)
    expect {
      credentials.find(Vouch::RecordKey.to_param(credential_class.where(tenant_id: "south", local_id: 4).first))
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "prunes composite-key password archives per owner", use_transactional_fixtures: false do
    suffix = unique_suffix
    owner_table = "cpk_password_owners_#{suffix}"
    archive_table = "cpk_password_archives_#{suffix}"
    create_composite_table(owner_table, [[:tenant_id, :string], [:local_id, :integer]],
      extra: [[:password_digest, :string]])
    create_composite_table(archive_table,
      [[:owner_tenant_id, :string], [:owner_local_id, :integer], [:sequence, :integer]],
      extra: [[:password_digest, :string], [:created_at, :datetime], [:updated_at, :datetime]])

    archive_name = "CpkPasswordArchive#{suffix}"
    owner_name = "CpkPasswordOwner#{suffix}"
    archive_class = Class.new(ApplicationRecord) do
      self.table_name = archive_table
      self.primary_key = %w[owner_tenant_id owner_local_id sequence]
      include Vouch::PasswordArchive::Concern
    end
    owner_class = Class.new(ApplicationRecord) do
      self.table_name = owner_table
      self.primary_key = %w[tenant_id local_id]
      include Vouch::Authenticatable
      has_secure_password
      has_many :password_archives,
        class_name: archive_name,
        foreign_key: %w[owner_tenant_id owner_local_id],
        primary_key: %w[tenant_id local_id]
      authenticates_with :password_trackable,
        password_trackable: { association: :password_archives, history_count: 2, history_window: 1.day }
    end
    stub_const(archive_name, archive_class)
    stub_const(owner_name, owner_class)
    archive_class.reset_column_information
    owner_class.reset_column_information

    north = owner_class.create!(tenant_id: "north", local_id: 7, password_digest: "current")
    south = owner_class.create!(tenant_id: "south", local_id: 7, password_digest: "current")
    3.times do |index|
      archive_class.create!(owner_tenant_id: north.tenant_id, owner_local_id: north.local_id,
        sequence: index + 1, password_digest: "north-#{index}", created_at: index.minutes.ago, updated_at: index.minutes.ago)
      archive_class.create!(owner_tenant_id: south.tenant_id, owner_local_id: south.local_id,
        sequence: index + 1, password_digest: "south-#{index}", created_at: index.minutes.ago, updated_at: index.minutes.ago)
    end

    north.send(:prune_old_password_archives)

    expect(north.password_archives.order(:sequence).pluck(:password_digest)).to eq(%w[north-0 north-1])
    expect(south.password_archives.order(:sequence).pluck(:password_digest)).to eq(%w[south-0 south-1 south-2])
  end

  private

  def unique_suffix
    "#{Process.pid}#{rand(1_000_000)}"
  end

  def quote_identifier(value)
    ActiveRecord::Base.connection.quote_table_name(value)
  end

  def create_composite_table(name, key_columns, extra: [])
    connection = ActiveRecord::Base.connection
    connection.create_table(name, id: false) do |table|
      key_columns.each { |column, type| table.public_send(type, column, null: false) }
      extra.each { |column, type| table.public_send(type, column) }
    end
    keys = key_columns.map { |column, _| connection.quote_column_name(column) }.join(", ")
    connection.execute("ALTER TABLE #{connection.quote_table_name(name)} ADD PRIMARY KEY (#{keys})")
  end
end
