# frozen_string_literal: true

class Users::InvitationsController < Vouch::InvitationsController
  private

  def authorize_invitation!
    true
  end

  def build_invited_account(identifier)
    identifier = identifier.to_s.strip.downcase
    existing = Account.find_by(email_address: identifier)
    return existing if existing

    Account.create!(
      email_address: identifier,
      registration_required: true,
      password:      SecureRandom.base64(48).truncate_bytes(64)
    )
  end
end
