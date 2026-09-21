# frozen_string_literal: true

# Test target for TokenVerifiable. Plays the role of an invitation-link
# row in host apps that confirm via clickable email URLs.
class CreateInvitationLinks < ActiveRecord::Migration[7.0]
  def change
    create_table :invitation_links do |t|
      t.string :recipient_email, null: false

      t.datetime :verified_at
      t.string   :confirmation_nonce

      t.timestamps
    end

    add_index :invitation_links, :verified_at
    add_index :invitation_links, :confirmation_nonce, unique: true
  end
end
