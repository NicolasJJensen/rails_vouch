# frozen_string_literal: true

module Vouch
  class Configuration
    # Configuration for the Recoverable concern. Recovery codes never
    # expire, so there is no TTL knob. Lockout protects
    # against brute-force enumeration; counter resets implicitly on
    # successful consume or explicit `generate_recovery_codes!`.
    #
    class RecoverableConfig
      attr_accessor :max_attempts, :lockout_duration

      def initialize(root_configuration = nil)
        @root_configuration = root_configuration
        @max_attempts     = 10
        @lockout_duration = nil
      end

      def lockout_duration
        @lockout_duration || @root_configuration&.lockout_duration || 30.minutes
      end

    end
  end
end
