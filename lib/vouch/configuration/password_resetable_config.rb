# frozen_string_literal: true

module Vouch
  class Configuration
    class PasswordResetableConfig
      attr_accessor :expiry, :token_strategy

      def initialize
        @expiry = 15.minutes
        @token_strategy = :signed
      end
    end
  end
end
