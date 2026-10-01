class AddPasswordlessToTwoFactorCredentials < ActiveRecord::Migration[8.1]
  def change
    change_table :two_factor_credentials do |t|
      t.string :sign_in_nonce
      t.bigint :sign_in_attempts, default: 0, null: false
      t.datetime :sign_in_locked_at
    end
  end
end
