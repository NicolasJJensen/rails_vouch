class AddPasswordResetNonceToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :password_reset_nonce, :string
  end
end
