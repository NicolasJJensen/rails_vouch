# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.references :account, null: false, foreign_key: true
      t.references :organisation, null: false, foreign_key: true

      # Invitations
      t.string :invitation_token
      t.datetime :invitation_sent_at
      t.datetime :invitation_accepted_at
      t.bigint :inviter_id

      t.timestamps
    end

    add_index :users, :invitation_token, unique: true
    add_index :users, :inviter_id
    add_foreign_key :users, :users, column: :inviter_id
  end
end
