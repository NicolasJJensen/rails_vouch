# frozen_string_literal: true

# Result returned by authentication operations. `value` carries a token or
# consumed record when the operation succeeds.
#
# Delivery exceptions propagate to the host controller so it can choose the
# appropriate response.
#
module Vouch
  Result = Struct.new(:status, :token, :metadata) do
    STATUSES = %i[ok invalid locked cancelled pending].freeze

    def initialize(status, token = nil, metadata = nil)
      raise ArgumentError, "unknown authentication result: #{status.inspect}" unless STATUSES.include?(status)

      super(status, token, metadata || {})
    end

    alias value token

    def ok?
      status == :ok
    end

    alias success? ok?

    def invalid?
      status == :invalid
    end

    def locked?
      status == :locked
    end

    def cancelled?
      status == :cancelled
    end

    def pending?
      status == :pending
    end

    def error
      metadata[:error]
    end

    def recovery_code?
      metadata[:recovery_code] == true
    end

    def self.ok(token = nil, **metadata)
      new(:ok, token, metadata)
    end

    def self.invalid(**metadata)
      new(:invalid, nil, metadata)
    end

    def self.locked(**metadata)
      new(:locked, nil, metadata)
    end

    def self.cancelled(**metadata)
      new(:cancelled, nil, metadata)
    end

    def self.pending(value = nil, **metadata)
      new(:pending, value, metadata)
    end
  end
end
