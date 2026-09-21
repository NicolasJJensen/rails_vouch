# frozen_string_literal: true

module Vouch
  class Configuration
    # Configuration for the BackupCodable concern — single-use recovery
    # codes generated at 2FA enrollment. Typically 10 codes of 8 hex chars
    # each (4 random bytes hex-encoded), which is the industry standard
    # (GitHub, Google, AWS).
    class BackupCodableConfig
      attr_accessor :code_count, :code_bytes, :warn_at_remaining

      def initialize(_root = nil)
        @code_count        = 10  # codes generated per regenerate!
        @code_bytes        = 4   # random bytes per code; 4 → 8 hex chars
        @warn_at_remaining = 3   # UI hint threshold; concern exposes .warn?
      end
    end
  end
end
