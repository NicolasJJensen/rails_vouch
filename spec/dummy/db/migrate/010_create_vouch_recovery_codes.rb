# frozen_string_literal: true

class CreateVouchRecoveryCodes < ActiveRecord::Migration[7.0]
  def change
    create_table :vouch_recovery_codes do |t|
      t.string   :recoverable_type, null: false
      t.bigint   :recoverable_id,   null: false
      t.string   :code_digest,      null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :vouch_recovery_codes,
              [:recoverable_type, :recoverable_id],
              name: "index_vouch_recovery_codes_on_recoverable"
  end
end
