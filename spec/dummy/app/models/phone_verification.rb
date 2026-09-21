# frozen_string_literal: true

# Dummy host for the Verifiable concern. Exercises the challenge / verify
# path that hosts will use for email + phone confirmation.
class PhoneVerification < ApplicationRecord
  include Vouch::Verifiable
  include Vouch::MagicLinkable

  self.verifiable_subject_attribute = :e164

  validates :e164, presence: true

  # Capture the issued code so specs can verify with a real OTP rather
  # than stubbing OtpCourier::OTP.consume.
  attr_accessor :last_delivered_code, :last_delivered_sign_in_code

  def deliver_verification_code(code)
    @last_delivered_code = code
  end

  def deliver_sign_in_code(code)
    @last_delivered_sign_in_code = code
  end
end
