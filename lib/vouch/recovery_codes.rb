# frozen_string_literal: true

# Shared, owner-agnostic recovery-code storage. Both accounts and individual
# two-factor credentials use this service; the owner supplies its relation and
# chooses the public configuration. A replacement set belongs only to that
# owner, so replacing a phone's codes never changes its account's codes.
module Vouch
  module RecoveryCodes
    ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789".chars.freeze

    module_function

    def normalize(value)
      value.to_s.gsub(/\s/, "").delete("-").upcase
    end

    def generate(count: Vouch.configuration.recovery_codes.code_count, length: Vouch.configuration.recovery_codes.code_length)
      raise ArgumentError, "Recovery code count and length must be positive integers" unless count.is_a?(Integer) && count.positive? && length.is_a?(Integer) && length.positive?

      Array.new(count) do
        Array.new(length) { ALPHABET.fetch(SecureRandom.random_number(ALPHABET.length)) }.join.scan(/.{1,4}/).join("-")
      end
    end

    def replace!(owner, relation:, plaintexts:, attributes: nil, after_replace: nil)
      digests = plaintexts.map { |code| BCrypt::Password.create(normalize(code)) }
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

    def consume!(owner, relation:, submitted:, normalize: ->(value) { RecoveryCodes.normalize(value) }, eligible: -> { true }, on_success: nil, on_failure: nil)
      code = normalize.call(submitted)
      return Vouch::Result.locked(record: owner) unless eligible.call

      Vouch::Persistence.transaction(owner) do
        owner.lock!
        next Vouch::Result.locked(record: owner) unless eligible.call

        current_relation = relation.respond_to?(:call) ? relation.call : relation unless code.blank?
        rows = code.blank? ? [] : current_relation.where(used_at: nil).lock.to_a
        match = rows.find { |row| BCrypt::Password.new(row.code_digest) == code } unless code.blank?
        if match
          Vouch::Persistence.update!(match, used_at: Time.current)
          on_success&.call(match)
          Vouch::Result.ok(match, recovery_code: true)
        else
          on_failure&.call
          Vouch::Result.invalid(record: owner)
        end
      end
    rescue Vouch::Persistence::Cancelled => error
      Vouch::Result.cancelled(record: owner, error: error)
    end
  end
end
