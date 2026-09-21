# frozen_string_literal: true

module Vouch
  class Configuration
    # Configuration for the Recoverable concern. Recovery codes never
    # expire, so there is no TTL knob. Lockout protects
    # against brute-force enumeration; counter resets implicitly on
    # successful consume or explicit `generate_recovery_codes!`.
    #
    class RecoverableConfig
      attr_accessor :code_count, :code_length, :max_attempts, :lockout_duration, :low_threshold

      def initialize(root_configuration = nil)
        @root_configuration = root_configuration
        @code_count       = 10
        @code_length      = 8
        @max_attempts     = 10
        @lockout_duration = nil
        @low_threshold    = 3
      end

      def lockout_duration
        @lockout_duration || @root_configuration&.lockout_duration || 30.minutes
      end

    end
  end
end
