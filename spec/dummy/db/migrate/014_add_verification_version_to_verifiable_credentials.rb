# frozen_string_literal: true

class AddVerificationVersionToVerifiableCredentials < ActiveRecord::Migration[7.0]
  def change
    add_column :phone_verifications, :verification_version, :bigint, default: 0, null: false
    add_column :two_factor_credentials, :verification_version, :bigint, default: 0, null: false
  end
end
