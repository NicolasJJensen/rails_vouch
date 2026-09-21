# frozen_string_literal: true

module Vouch
  class Configuration
    class InvitationsConfig
      attr_accessor :expiry

      def initialize
        @expiry = 7.days
      end
    end
  end
end
