# frozen_string_literal: true

module Vouch
  class Configuration
    class RecoveryCodesConfig
      attr_accessor :code_count, :code_length, :low_threshold

      def initialize
        @code_count = 10
        @code_length = 8
        @low_threshold = 3
      end
    end
  end
end
