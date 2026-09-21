# frozen_string_literal: true

module Vouch
  class Configuration
    # Configuration for the TwoFactorable concern. `challenge_validity`
    # names the validity window of the issued challenge
    # *token* — distinct from the TOTP code window, which is managed by
    # ROTP and not configurable here.
    #
    class TwoFactorableConfig
      attr_accessor :challenge_validity, :max_attempts, :lockout_duration, :length

      def initialize(root_configuration = nil)
        @root_configuration = root_configuration
        @challenge_validity = 5.minutes
        @max_attempts       = 5
        @lockout_duration   = nil
        @length             = 6
      end

      def lockout_duration
        @lockout_duration || @root_configuration&.lockout_duration || 30.minutes
      end

    end
  end
end
