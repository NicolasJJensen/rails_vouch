# frozen_string_literal: true

class CreateBackupCodes < ActiveRecord::Migration[7.0]
  def change
    create_table :backup_codes do |t|
      t.references :two_factor_credential, null: false, foreign_key: true
      t.string     :code_digest, null: false
      t.datetime   :used_at
      t.timestamps
    end

    add_index :backup_codes, :used_at
  end
end
