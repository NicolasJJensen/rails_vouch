# frozen_string_literal: true

class CreateOmniAuthIdentities < ActiveRecord::Migration[7.0]
  def change
    create_table :omni_auth_identities do |t|
      t.references :account, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :uid, null: false
      t.text :auth_data

      t.timestamps
    end

    add_index :omni_auth_identities, [:provider, :uid], unique: true
  end
end
