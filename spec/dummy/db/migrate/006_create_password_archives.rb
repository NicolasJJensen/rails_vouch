# frozen_string_literal: true

class CreatePasswordArchives < ActiveRecord::Migration[7.0]
  def change
    create_table :password_archives do |t|
      t.references :account, null: false, foreign_key: true
      t.string :password_digest, null: false

      t.timestamps
    end
  end
end
