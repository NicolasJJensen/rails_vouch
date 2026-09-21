# frozen_string_literal: true

class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def registration_tenant_attributes(account)
    { name: "#{account.email_address}'s Organisation" }
  end
end
