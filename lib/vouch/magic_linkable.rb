# frozen_string_literal: true

# MagicLinkable concern — passwordless sign-in via a one-time code
# delivered over a contactable channel (email link, SMS code, etc.).
#
# Distinct from Verifiable (which proves ownership once, at add time) and
# TwoFactorable (which challenges an already-authenticated session as the
# second factor). MagicLinkable is the primary authentication event —
# verify_sign_in_code returning true IS the sign-in.
#
# Same-session mutual exclusion with 2FA is enforced upstream, not on the
# row. When magic-link sign-in succeeds, controllers stash
# `{"type", "id"}` in the session's `:signed_in_via` slot; the 2FA challenge
# filter removes that credential from the picker for the current session
# only. See Vouch::ControllerHelpers#two_factor_credentials_for.
#
# Required columns (added by `bin/rails g vouch:magic_linkable`):
#   - sign_in_attempts:integer default: 0, null: false
#   - sign_in_locked_at:datetime
#   - sign_in_nonce:string (nullable)
#   - created_at:datetime (validated when the feature is used)
#
# Public surface:
#   - #sign_in_locked?
#   - #issue_sign_in_code!            => Result.ok(token) | Result.locked
#   - #verify_sign_in_code(code, token:) => Result
#
# Hosts override #deliver_sign_in_code(code) per credential type.
#
module Vouch
  module MagicLinkable
    extend ActiveSupport::Concern
    include Vouch::LockoutCounter
    include Vouch::ChallengeNonce

    def sign_in_locked?
      locked_window_open?(
        locked_at_attr:   :sign_in_locked_at,
        lockout_duration: magic_linkable_config.lockout_duration
      )
    end

    # Issue a one-time sign-in code. Requires a persisted credential —
    # you can't sign in with an unsaved row. Delivery exceptions raised
    # by `deliver_sign_in_code` bubble; hosts rescue at the controller
    # level, same convention as Verifiable.
    def issue_sign_in_code!
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:magic_linkable, self.class))
      raise ArgumentError, "cannot sign in with an unpersisted record" unless persisted?
      return Vouch::Result.locked if sign_in_locked?

      nonce = issue_nonce!(:sign_in_nonce)
      issued = OtpCourier::OTP.issue(
        purpose:  Vouch::Purposes.sign_in(self),
        payload:  sign_in_payload.merge("nonce" => nonce),
        validity: magic_linkable_config.validity,
        length:   magic_linkable_config.length
      )

      deliver_sign_in_code(issued.code)

      Vouch::Result.ok(issued.token)
    end

    # Verify a submitted sign-in code. Does NOT set verified_at (that's
    # Verifiable's job) or two_factor_last_used_at (that's TwoFactorable's).
    # Returns Result.ok on success; caller then set_user's the associated account.
    def verify_sign_in_code(code, token:)
      self.class.validate_auth_schema!(*Vouch::FeatureContracts.columns_for(:magic_linkable, self.class))
      return Vouch::Result.locked if sign_in_locked?

      code = code.to_s.strip

      payload = consume_otp_token(token, code, Vouch::Purposes.sign_in(self))

      if sign_in_payload_valid?(payload)
        transaction_result = Vouch::Persistence.transaction(self) do
          lock!
          next Vouch::Result.invalid if sign_in_locked?
          next Vouch::Result.invalid unless sign_in_payload_valid?(payload)

          Vouch::Persistence.update!(self, sign_in_attempts: 0, sign_in_locked_at: nil, sign_in_nonce: nil)
        end
        transaction_result.is_a?(Vouch::Result) ? transaction_result : Vouch::Result.ok
      else
        bump_lockout_counter!(
          counter_attr:     :sign_in_attempts,
          locked_at_attr:   :sign_in_locked_at,
          max_attempts:     magic_linkable_config.max_attempts,
          lockout_duration: magic_linkable_config.lockout_duration
        )
        Vouch::Result.invalid
      end
    rescue Vouch::Persistence::Cancelled
      Vouch::Result.cancelled
    end

    # Host delivery hook. Override per credential type:
    #
    #   def deliver_sign_in_code(code)
    #     SmsCourier.send(e164, "Your sign-in code: #{code}")
    #   end
    #
    def deliver_sign_in_code(_code)
      raise Vouch::ConfigurationError,
        "#{self.class.name} must implement #deliver_sign_in_code(code)"
    end

    private

    # Mutable contact credentials commonly combine MagicLinkable with
    # Verifiable. Bind sign-in challenges to the same subject/version in that
    # case so changing the address or phone invalidates outstanding links.
    def sign_in_payload
      payload = { "id" => Vouch::RecordKey.value(self), "klass" => self.class.name }
      if respond_to?(:verifiable_subject)
        payload["subject"] = verifiable_subject
        payload["version"] = verifiable_subject_version
      end
      payload
    end

    def sign_in_payload_valid?(payload)
      return false unless payload_valid?(payload) && nonce_matches?(payload, :sign_in_nonce)
      return true unless respond_to?(:verifiable_subject)

      payload["subject"] == verifiable_subject &&
        payload["version"].is_a?(Integer) &&
        payload["version"] == verifiable_subject_version
    end

    def magic_linkable_config
      Vouch.configuration.magic_linkable
    end
  end
end
