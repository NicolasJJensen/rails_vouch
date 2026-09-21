# frozen_string_literal: true

# Raised at `include Vouch::Verifiable` / `TwoFactorable` time when
# the host table is missing a column the concern depends on (`created_at`,
# attempt counters, lockout timestamps). Surfaces schema mistakes at boot
# instead of at the first verify call.
#
module Vouch
  class SchemaError < StandardError; end
end
