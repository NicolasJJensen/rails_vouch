class AddInvitationRejectedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :invitation_rejected_at, :datetime
  end
end
