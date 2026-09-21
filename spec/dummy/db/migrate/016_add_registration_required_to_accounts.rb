# frozen_string_literal: true

class AddRegistrationRequiredToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :registration_required, :boolean, default: false, null: false
  end
end
