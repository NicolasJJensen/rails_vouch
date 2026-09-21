# frozen_string_literal: true

class AddInvitationRegistrationRequiredToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :invitation_registration_required, :boolean, default: false, null: false
  end
end
