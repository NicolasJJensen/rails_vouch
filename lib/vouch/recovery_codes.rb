# frozen_string_literal: true

# Shared, owner-agnostic recovery-code storage. Both accounts and individual
# two-factor credentials use this service; the owner supplies its relation and
# chooses the public configuration. A replacement set belongs only to that
# owner, so replacing a phone's codes never changes its account's codes.
module Vouch
  module RecoveryCodes
    module_function

    def replace!(owner, relation:, plaintexts:, attributes: nil, after_replace: nil)
      digests = plaintexts.map { |code| BCrypt::Password.create(code) }
      Vouch::Persistence.transaction(owner) do
        owner.lock!
        # Recovery-code replacement is a security operation. Honour host
        # destroy callbacks so an application can cancel replacement, and
        # keep the old set intact when it does.
        relation.find_each { |row| Vouch::Persistence.destroy!(row) }
        digests.each do |digest|
          Vouch::Persistence.create!(relation, **(attributes || {}).merge(code_digest: digest))
        end
        after_replace&.call
      end
      Vouch::Result.ok(plaintexts)
    end

    def consume!(owner, relation:, submitted:, normalize: ->(value) { value.to_s.strip }, eligible: -> { true }, on_success: nil, on_failure: nil)
      code = normalize.call(submitted)
      return Vouch::Result.invalid if code.blank?
      return Vouch::Result.locked unless eligible.call

      Vouch::Persistence.transaction(owner) do
        owner.lock!
        next Vouch::Result.locked unless eligible.call

        rows = relation.where(used_at: nil).lock.to_a
        match = rows.find { |row| BCrypt::Password.new(row.code_digest) == code }
        if match
          Vouch::Persistence.update!(match, used_at: Time.current)
          on_success&.call(match)
          Vouch::Result.ok(match, recovery_code: true)
        else
          on_failure&.call
          Vouch::Result.invalid
        end
      end
    rescue Vouch::Persistence::Cancelled
      Vouch::Result.cancelled
    end
  end
end
