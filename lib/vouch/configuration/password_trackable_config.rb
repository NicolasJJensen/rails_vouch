# frozen_string_literal: true

module Vouch
  class Configuration
    class PasswordTrackableConfig
      attr_accessor :history_count, :history_window, :association

      def initialize
        @history_count  = 5
        @history_window = 1.month
      end
    end
  end
end
