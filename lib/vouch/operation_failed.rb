# frozen_string_literal: true

module Vouch
  class OperationFailed < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super("Authentication operation failed (#{result.status})")
    end
  end
end
