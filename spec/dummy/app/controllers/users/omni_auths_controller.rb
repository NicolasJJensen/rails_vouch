# frozen_string_literal: true

class Users::OmniAuthsController < Vouch::OmniAuthsController
  private

  def build_tenant(account)
    Organisation.new(name: "#{account.email_address}'s Organisation")
  end

  def build_identity(account, tenant:)
    tenant.users.build(account: account)
  end
end
