# frozen_string_literal: true

# Test target for Verifiable. Plays the role of a phone-number row in host
# apps that confirm contacts via 6-digit codes.
class CreatePhoneVerifications < ActiveRecord::Migration[7.0]
  def change
    create_table :phone_verifications do |t|
      t.string   :e164, null: false

      t.datetime :verified_at
      t.bigint   :verification_attempts, default: 0, null: false
      t.datetime :verification_locked_at

      t.timestamps
    end

    add_index :phone_verifications, :verified_at
  end
end
