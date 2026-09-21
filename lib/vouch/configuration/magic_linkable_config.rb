# frozen_string_literal: true

module Vouch
  class Configuration
    # Configuration for the MagicLinkable concern — passwordless sign-in
    # via one-time codes delivered over the credential's transport.
    #
    # Separate namespace from Verifiable and TwoFactorable so hosts can
    # tune sign-in windows/attempts independently. A longer validity
    # window is common here (users receive the code via SMS/email and may
    # take a minute to switch apps and paste it).
    class MagicLinkableConfig
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
