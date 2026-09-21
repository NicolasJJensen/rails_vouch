# frozen_string_literal: true

class AddTwoFactorEnabledToAccounts < ActiveRecord::Migration[7.0]
  def up
    add_column :accounts, :two_factor_enabled, :boolean, default: false, null: false

    execute <<~SQL
      UPDATE accounts
      SET two_factor_enabled = TRUE
      WHERE EXISTS (
        SELECT 1 FROM two_factor_credentials
        WHERE two_factor_credentials.account_id = accounts.id
          AND two_factor_credentials.two_factor_enabled_at IS NOT NULL
      )
    SQL
  end

  def down
    remove_column :accounts, :two_factor_enabled
  end
end
