# frozen_string_literal: true

# Persistent recovery-code row. Polymorphic on `recoverable` so it can
# attach to whatever the host calls its user-equivalent model.
#
# BCrypt-hashed at rest. Never reversible — display happens once at
# generation time and the gem never reproduces plaintext.
#
# Columns (added by `bin/rails g vouch:recoverable`):
#   - recoverable_type:string  (polymorphic; null: false)
#   - recoverable_id           (polymorphic; null: false)
#   - code_digest:string       (null: false)
#   - used_at:datetime
#   - created_at, updated_at
#
# Index: composite (recoverable_type, recoverable_id) — accounts have ~10
# rows each, so a per-account scan is microseconds (decision 35).
#
module Vouch
  class RecoveryCode < ActiveRecord::Base
    self.table_name = "vouch_recovery_codes"

    belongs_to :recoverable, polymorphic: true

    scope :unused, -> { where(used_at: nil) }
    scope :used,   -> { where.not(used_at: nil) }

    def used?
      used_at.present?
    end
  end
end
