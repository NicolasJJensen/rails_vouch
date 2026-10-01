class AddHostFieldsToOauthIdentities < ActiveRecord::Migration[8.1]
  def change
    add_column :omni_auth_identities, :provider_nickname, :string
    add_column :omni_auth_identities, :primary, :boolean, default: false, null: false
  end
end
