# frozen_string_literal: true

# Shared private helpers for the lock-then-increment-then-check-threshold
# pattern used by Verifiable, TwoFactorable, and Recoverable.
#
# Five separate copies of the critical section drift; one shared module
# stays correct. The three concerns each `include Vouch::LockoutCounter`
# and call these helpers.
#
# Recoverable inlines its own bump path because it is already
# inside a host-row-locked outer transaction — wrapping another `with_lock`
# would be redundant. It still picks up `consume_otp_token`,
# `locked_window_open?`, and `payload_valid?` from this module.
#
require_relative "persistence"

module Vouch
  module LockoutCounter
    extend ActiveSupport::Concern

    private

    # OtpCourier returns nil for invalid proofs. Unexpected verifier failures
    # must propagate so an outage cannot count as a user's failed attempt.
    def consume_otp_token(token, code, purpose)
      OtpCourier::OTP.consume(token, code, purpose: purpose)
    end

    # Lock-then-increment-then-check-threshold. Called from the failure
    # branch of every verify path. Sets `locked_at_attr` when the counter
    # reaches `max_attempts`, unless an active lock already exists.
    def bump_lockout_counter!(counter_attr:, locked_at_attr:, max_attempts:, lockout_duration:)
      Vouch::Persistence.transaction(self) do
        lock!
        attempts = public_send(counter_attr).to_i + 1

        if attempts >= max_attempts &&
           !locked_window_open?(locked_at_attr: locked_at_attr, lockout_duration: lockout_duration)
          Vouch::Persistence.update!(self, counter_attr => attempts, locked_at_attr => Time.current)
        else
          increment!(counter_attr)
        end
      end
    end

    # True when `locked_at_attr` is set and is younger than `lockout_duration`.
    # Boundary is open-ended on the older side — at exact `lockout_duration.ago`,
    # returns false.
    def locked_window_open?(locked_at_attr:, lockout_duration:)
      locked_at = public_send(locked_at_attr)
      return false unless locked_at
      locked_at > lockout_duration.ago
    end

    # Defence-in-depth payload re-check shared across concerns. It requires a
    # hash, a string-compared primary key, and the concrete class name to
    # prevent cross-record and STI confusion.
    def payload_valid?(payload)
      payload.is_a?(Hash) &&
        Vouch::RecordKey.same?(payload["id"], Vouch::RecordKey.value(self), model: self.class) &&
        payload["klass"] == self.class.name
    end
  end
end
