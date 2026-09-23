# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Recoverable with composite primary keys" do
  before do
    connection = ActiveRecord::Base.connection
    connection.create_table(:vouch_cpk_recovery_owners, id: false) do |t|
      t.string :tenant_id, null: false
      t.integer :local_id, null: false
      t.integer :recovery_attempts, null: false, default: 0
      t.datetime :recovery_locked_at
      t.timestamps
    end
    connection.add_column(:vouch_recovery_codes, :recoverable_key, :string) unless
      connection.column_exists?(:vouch_recovery_codes, :recoverable_key)
    connection.change_column_null(:vouch_recovery_codes, :recoverable_id, true)
    Vouch::RecoveryCode.reset_column_information

    owner_class = Class.new(ActiveRecord::Base) do
      self.table_name = "vouch_cpk_recovery_owners"
      self.primary_key = %i[tenant_id local_id]
      include Vouch::Recoverable
    end
    stub_const("CpkRecoveryOwner", owner_class)
  end

  after do
    connection = ActiveRecord::Base.connection
    connection.drop_table(:vouch_cpk_recovery_owners, if_exists: true)
    connection.remove_column(:vouch_recovery_codes, :recoverable_key) if
      connection.column_exists?(:vouch_recovery_codes, :recoverable_key)
    connection.execute("DELETE FROM vouch_recovery_codes WHERE recoverable_id IS NULL")
    connection.change_column_null(:vouch_recovery_codes, :recoverable_id, false)
    Vouch::RecoveryCode.reset_column_information
  end

  it "isolates owners that share a local component and cleans up their codes" do
    first = CpkRecoveryOwner.create!(tenant_id: "alpha", local_id: 7)
    second = CpkRecoveryOwner.create!(tenant_id: "beta", local_id: 7)

    generated = first.generate_recovery_codes!
    code = generated.value.first
    expect(first.vouch_recovery_codes.count).to eq(Vouch.configuration.recoverable.code_count)
    expect(first.vouch_recovery_codes.first.recoverable).to eq(first)
    expect(second.vouch_recovery_codes).to be_empty

    expect(second.consume_recovery_code!(code)).to be_invalid
    expect(first.consume_recovery_code!(code)).to be_ok

    first.destroy!
    expect(Vouch::RecoveryCode.where(recoverable_key: Vouch::RecordKey.dump(first))).to be_empty
    expect(second.vouch_recovery_codes).to be_empty
  end
end
