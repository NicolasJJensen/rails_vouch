class AddConfirmationNonceToPhoneVerifications < ActiveRecord::Migration[8.1]
  def change
    add_column :phone_verifications, :confirmation_nonce, :string
  end
end
