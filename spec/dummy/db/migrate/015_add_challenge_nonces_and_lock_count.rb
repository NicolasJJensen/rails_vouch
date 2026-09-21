class AddChallengeNoncesAndLockCount < ActiveRecord::Migration[7.0]
  def change
    add_column :phone_verifications, :verification_nonce, :string
    add_column :phone_verifications, :sign_in_nonce, :string
    add_column :two_factor_credentials, :verification_nonce, :string
    add_column :two_factor_credentials, :two_factor_nonce, :string
    add_column :accounts, :consecutive_locks, :bigint, default: 0, null: false
  end
end
