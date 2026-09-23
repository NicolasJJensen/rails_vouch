# frozen_string_literal: true

# Centralized purpose-string construction for otp_courier tokens.
#
# Per-record purposes include the credential's class and a typed key transport,
# and a microsecond timestamp suffix. The timestamp defends against
# `record.dup.save!` inside the same wall-clock second producing two records
# that share a purpose namespace.
#
# Scope-level purposes (invitations, password resets, magic links) don't
# need the per-record disambiguation — they're keyed by the scope and the
# flow name.
#
module Vouch
  module Purposes
    class << self
      def verify(record)
        if record.persisted?
          per_record(record, :verify)
        else
          # Drafts have no id and no created_at. Key by class + natural
          # identifier — the same subject the payload carries. The
          # "draft." infix isolates draft purposes from the persisted
          # format ("verify.<class>.<id>.<ts>"), so a natural id that
          # happened to look like "<int>.<int>" can't collide.
          "verify.draft.#{record.class.name.underscore}.#{record.verifiable_subject}"
        end
      end

      def two_factor(record)
        per_record(record, :two_factor)
      end

      # Magic-link sign-in purpose. Persisted-only — you can't sign in
      # with an unpersisted credential — so the per-record format applies
      # unconditionally.
      def sign_in(record)
        per_record(record, :sign_in)
      end

      def invitation(scope)
        "#{scope}.invitation"
      end

      def password_reset(scope)
        "#{scope}.password_reset"
      end

      def magic_link(scope)
        "#{scope}.magic_link"
      end

      private

      def per_record(record, action)
        ts = record.created_at&.strftime("%s%6N") or raise SchemaError, <<~MSG.squish
          #{record.class.name} record is missing #created_at — purpose strings
          can't be built without it. Verifiable / TwoFactorable require a
          created_at column on the host table.
        MSG

        "#{action}.#{record.class.name.underscore}.#{Vouch::RecordKey.serialize(record)}.#{ts}"
      end
    end
  end
end
