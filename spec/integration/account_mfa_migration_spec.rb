# frozen_string_literal: true

require "rails_helper"
require "pg"

RSpec.describe "account MFA backfill migration", :migration do
  self.use_transactional_tests = false

  it "preserves enabled verified and unverified credentials and leaves others disabled" do
    connection = ActiveRecord::Base.connection
    ddl = PG.connect(dbname: connection_db_name)
    schema = "vouch_mfa_migration_#{Process.pid}_#{rand(100_000)}"
    previous_search_path = connection.schema_search_path

    ddl.exec("CREATE SCHEMA \"#{schema}\"")
    connection.schema_search_path = schema
    ddl.exec("SET search_path TO \"#{schema}\"")
    ddl.exec(<<~SQL)
      CREATE TABLE accounts (
        id bigserial PRIMARY KEY
      );
      CREATE TABLE two_factor_credentials (
        id bigserial PRIMARY KEY,
        account_id bigint NOT NULL,
        verified_at timestamp,
        two_factor_enabled_at timestamp
      );
    SQL

    accounts = 3.times.map { connection.exec_query("INSERT INTO accounts DEFAULT VALUES RETURNING id").first["id"] }
    now = Time.current.iso8601
    connection.exec_query(<<~SQL)
      INSERT INTO two_factor_credentials (account_id, verified_at, two_factor_enabled_at)
      VALUES
        (#{accounts[0]}, '#{now}', '#{now}'),
        (#{accounts[1]}, NULL, '#{now}')
    SQL

    migration_path = Rails.root.join("db/migrate/017_add_two_factor_enabled_to_accounts.rb")
    load migration_path
    AddTwoFactorEnabledToAccounts.new.migrate(:up)

    result = connection.exec_query("SELECT id, two_factor_enabled FROM accounts ORDER BY id").to_a
    expect(result.map { |row| row["two_factor_enabled"] }).to eq([true, true, false])
  ensure
    connection.schema_search_path = previous_search_path if connection && previous_search_path
    ddl&.exec("DROP SCHEMA IF EXISTS \"#{schema}\" CASCADE")
    ddl&.close
  end

  private

  def connection_db_name
    ActiveRecord::Base.connection_db_config.database
  end
end
