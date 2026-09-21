# frozen_string_literal: true

class AddMagicLinkableToPhoneVerifications < ActiveRecord::Migration[7.0]
  def change
    change_table :phone_verifications do |t|
      t.bigint   :sign_in_attempts,  default: 0, null: false
      t.datetime :sign_in_locked_at
    end
  end
end
