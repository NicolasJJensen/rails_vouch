# frozen_string_literal: true

module Vouch
  class Configuration
    class PasswordResetableConfig
      attr_accessor :expiry

      def initialize
        @expiry = 15.minutes
      end
    end
  end
end
