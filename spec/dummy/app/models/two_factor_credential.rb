# frozen_string_literal: true

# Dummy-app 2FA credential. Mixes in the new TwoFactorable concern. The
# host owns delivery — TOTP renders no code (the QR is generated at
# enrollment time and read out-of-band), so `deliver_two_factor_code` is
# a no-op and `challenge!` is overridden to skip OTP issuance entirely.
#
class TwoFactorCredential < ApplicationRecord
  include Vouch::Verifiable
  include Vouch::TwoFactorable
  include Vouch::BackupCodable

  self.inheritance_column = nil # Disable STI — type stores method kind, not a class name
  self.verifiable_subject_attribute = :otp_secret
  self.two_factor_label_attribute = :type

  belongs_to :account
  has_many :backup_codes, dependent: :destroy

  # TOTP fork: replace the courier-issued OTP with a TOTP-derived one.
  # For non-TOTP credentials, delegate to the inherited stateless flow.
  def challenge!
    raise ArgumentError, "cannot challenge an unpersisted record" unless persisted?
    return Vouch::Result.locked unless two_factor_enabled? && verified?

    if otp_secret.present?
      return Vouch::Result.locked if two_factor_locked?
      Vouch::Result.ok(:totp)
    else
      super
    end
  end

  def verify_challenge(code, token:)
    return Vouch::Result.locked if two_factor_locked? || !two_factor_enabled? || !verified?

    if otp_secret.present?
      code = code.to_s.strip
      Vouch::Persistence.transaction(self) do
        lock!
          next Vouch::Result.locked if two_factor_locked? || !two_factor_enabled? || !verified?
        timestep = ROTP::TOTP.new(otp_secret).verify(code, drift_behind: 30, drift_ahead: 30,
          after: two_factor_last_used_at&.to_i)
        if timestep
          Vouch::Persistence.update!(self,
            two_factor_failed_attempts: 0,
            two_factor_locked_at:       nil,
            two_factor_last_used_at:    Time.at(timestep))
          Vouch::Result.ok
        else
          config = two_factorable_config
          bump_lockout_counter!(counter_attr:     :two_factor_failed_attempts,
                                locked_at_attr:   :two_factor_locked_at,
                                max_attempts:     config.max_attempts,
                                lockout_duration: config.lockout_duration)
          Vouch::Result.invalid
        end
      end
    else
      super
    end
  rescue Vouch::Persistence::Cancelled
    Vouch::Result.cancelled
  end

  def deliver_two_factor_code(_code)
    # TOTP credentials are read out-of-band by the host.
  end

  def deliver_verification_code(_code)
    # Dummy host delivery for the Verifiable concern.
  end
end
