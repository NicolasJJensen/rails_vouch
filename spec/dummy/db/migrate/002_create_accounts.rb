# frozen_string_literal: true

class CreateAccounts < ActiveRecord::Migration[7.0]
  def change
    create_table :accounts do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false

      # Lockable
      t.datetime :locked_at
      t.integer :failed_attempts, default: 0, null: false

      # Two-factor
      t.integer :two_factor_attempts, default: 0, null: false

      # Password reset (C1)
      t.string :password_reset_token_digest
      t.datetime :password_reset_sent_at

      t.timestamps
    end

    add_index :accounts, :email_address, unique: true
    add_index :accounts, :password_reset_token_digest, unique: true
    add_index :accounts, :password_reset_sent_at
  end
end
