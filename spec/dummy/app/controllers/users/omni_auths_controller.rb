# frozen_string_literal: true

class Users::OmniAuthsController < Vouch::OmniAuthsController
  private

  def registration_tenant_attributes(account)
    { name: "#{account.email_address}'s Organisation" }
  end
end
