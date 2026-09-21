# frozen_string_literal: true

class CreateTwoFactorCredentials < ActiveRecord::Migration[7.0]
  def change
    create_table :two_factor_credentials do |t|
      t.references :account, null: false, foreign_key: true
      t.string :type
      t.string :otp_secret
      t.string :phone_number
      t.boolean :enabled, default: false, null: false

      # Verifiable columns
      t.datetime :verified_at
      t.bigint   :verification_attempts, default: 0, null: false
      t.datetime :verification_locked_at

      # TwoFactorable columns
      t.datetime :two_factor_enabled_at
      t.bigint   :two_factor_failed_attempts, default: 0, null: false
      t.datetime :two_factor_locked_at
      t.datetime :two_factor_last_used_at

      t.timestamps
    end

    add_index :two_factor_credentials, [:account_id, :enabled]
  end
end
