# frozen_string_literal: true

class AddRecoverableToAccounts < ActiveRecord::Migration[7.0]
  def change
    change_table :accounts do |t|
      t.bigint   :recovery_attempts, default: 0, null: false
      t.datetime :recovery_locked_at
    end
  end
end
