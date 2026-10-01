# frozen_string_literal: true

module Vouch
  class Configuration
    class PasswordTrackableConfig
      attr_reader :history_count, :history_window
      attr_accessor :association

      def self.validate!(name, value)
        valid = case name.to_sym
        when :history_count then value.is_a?(Integer) && value >= 0
        when :history_window
          value.respond_to?(:ago) && value.respond_to?(:to_f) && value.to_f.finite? && value.to_f >= 0
        else true
        end
        raise Vouch::ConfigurationError, "password_trackable.#{name} must be a nonnegative #{name.to_sym == :history_count ? 'integer' : 'duration'}" unless valid
        value
      end

      def history_count=(value)
        @history_count = self.class.validate!(:history_count, value)
      end

      def history_window=(value)
        @history_window = self.class.validate!(:history_window, value)
      end

      def initialize
        @history_count  = 5
        @history_window = 1.month
      end
    end
  end
end
