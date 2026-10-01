# frozen_string_literal: true

class UseCitextForAccountEmails < ActiveRecord::Migration[8.1]
  def up
    enable_extension "citext" unless extension_enabled?("citext")
    unless column_exists?(:accounts, :email_address, :citext)
      change_column :accounts, :email_address, :citext
    end
  end

  def down
    change_column :accounts, :email_address, :string
  end
end
