# frozen_string_literal: true

class AllowAccountsWithoutPasswords < ActiveRecord::Migration[8.1]
  def change
    change_column_null :accounts, :password_digest, true
  end
end
