# frozen_string_literal: true

module Vouch
  class Configuration
    # Configuration for the Verifiable concern. Holds the validity window
    # for issued verification tokens, the lockout threshold/duration, and
    # the per-code length (mostly so host overrides can shorten it without
    # touching otp_courier config directly).
    #
    # Code character set (numeric vs. alphanumeric) is a per-call argument
    # to OtpCourier::OTP.issue and isn't surfaced here.
    #
    class VerifiableConfig
      attr_accessor :validity, :max_attempts, :lockout_duration, :length

      def initialize(root_configuration = nil)
        @root_configuration = root_configuration
        @validity         = 10.minutes
        @max_attempts     = 5
        @lockout_duration = nil
        @length           = 6
      end

      def lockout_duration
        @lockout_duration || @root_configuration&.lockout_duration || 30.minutes
      end

    end
  end
end
