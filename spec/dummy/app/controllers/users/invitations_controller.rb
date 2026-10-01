# frozen_string_literal: true

class Users::InvitationsController < Vouch::InvitationsController
  private

  def build_invited_account(identifier)
    identifier = identifier.to_s.strip.downcase
    existing = Account.find_by(email_address: identifier)
    return existing if existing

    Account.new(
      email_address: identifier,
      registration_required: true
    )
  end
end
