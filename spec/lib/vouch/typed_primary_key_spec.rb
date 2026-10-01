require "rails_helper"

RSpec.describe "Typed primary keys" do
  before do
    ApplicationRecord.connection.create_table(:typed_reset_accounts, id: false, temporary: true) do |table|
      table.boolean :enabled
      table.datetime :recorded_at, precision: 6
      table.date :registered_on, null: false
      table.decimal :external_number, precision: 20, scale: 8, null: false
      table.string :email_address
      table.string :password_digest
      table.string :password_reset_nonce
    end
    stub_const("TypedResetAccount", Class.new(ApplicationRecord) do
      self.table_name = "typed_reset_accounts"
      self.primary_key = %w[registered_on external_number]
      include Vouch::Authenticatable
      authenticates_with :password_resetable, password_resetable: {token_strategy: :signed}
      has_secure_password

      def self.password_reset_verifier
        @verifier ||= ActiveSupport::MessageVerifier.new("typed-key-regression", serializer: JSON)
      end
    end)
  end

  after do
    ApplicationRecord.connection.drop_table(:typed_reset_accounts, if_exists: true)
  end

  it "finds date and decimal composite keys within a scoped relation" do
    record = TypedResetAccount.create!(registered_on: Date.new(2026, 10, 1),
      external_number: BigDecimal("123456.12345678"), password: "initial-password")
    relation = TypedResetAccount.where(registered_on: record.registered_on)
    expect(Vouch::RecordKey.find(relation, Vouch::RecordKey.to_param(record))).to eq(record)
    expect(Vouch::RecordKey.find(relation, Vouch::RecordKey.to_param(record)).external_number).to eq(record.external_number)
  end

  it "resolves and consumes signed reset tokens after JSON converts typed keys" do
    record = TypedResetAccount.create!(registered_on: Date.new(2026, 10, 1),
      external_number: BigDecimal("123456.12345678"), password: "initial-password")
    token = record.generate_password_reset_token!.value
    expect(TypedResetAccount.find_by_auth_password_reset_token(token)).to eq(record)
    expect(record.reset_password_with_token(token, password: "replacement-password")).to be_ok
    expect(record.reload.authenticate("replacement-password")).to eq(record)
    expect(TypedResetAccount.find_by_auth_password_reset_token(token)).to be_nil
  end
  it "consumes signed reset tokens for a false boolean primary key" do
    TypedResetAccount.primary_key = "enabled"
    TypedResetAccount.insert_all!([{enabled: false, registered_on: Date.new(2026, 10, 1),
      external_number: BigDecimal("1"), password_digest: BCrypt::Password.create("initial-password")}])
    record = TypedResetAccount.find_by!(enabled: false)
    token = record.generate_password_reset_token!.value
    expect(TypedResetAccount.find_by_auth_password_reset_token(token).attributes).to eq(record.attributes)
    expect(record.reset_password_with_token(token, password: "replacement-password")).to be_ok
  end

  it "preserves database timestamp precision in scalar and composite signed-reset keys" do
    ["recorded_at", %w[recorded_at external_number]].each do |primary_key|
      TypedResetAccount.primary_key = primary_key
      record = TypedResetAccount.create!(registered_on: Date.new(2026, 10, 1),
        recorded_at: Time.iso8601("2026-10-01T12:34:56.123456Z"),
        external_number: BigDecimal("123456.12345678"), password: "initial-password")
      token = record.generate_password_reset_token!.value
      expect(TypedResetAccount.find_by_auth_password_reset_token(token)).to eq(record)
      expect(record.reset_password_with_token(token, password: "replacement-password")).to be_ok
      record.destroy!
    end
  end

end
