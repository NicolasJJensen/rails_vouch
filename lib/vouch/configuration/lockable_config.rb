# frozen_string_literal: true

module Vouch
  class Configuration
    class LockableConfig
      attr_reader :max_failed_attempts, :strategy, :invalidate_sessions_on_lockout
      attr_writer :max_failed_attempts, :strategy, :lockout_duration,
                  :invalidate_sessions_on_lockout

      def initialize(root_configuration = nil)
        @root_configuration  = root_configuration
        @max_failed_attempts = 5
        @lockout_duration    = nil  # nil = inherit from root
        @strategy            = :failed_attempts
        @invalidate_sessions_on_lockout = false
      end

      # Lockout duration cascade: own value if set, else root config.
      def lockout_duration
        @lockout_duration || @root_configuration&.lockout_duration
      end
    end
  end
end
