# frozen_string_literal: true

# Prevents password reuse by maintaining a history of recent passwords.
#
# Checks new passwords against the last `auth_config(:password_trackable, :history_count)`
# passwords within `auth_config(:password_trackable, :history_window)`.
#
# The has_many association is declared by the host app and discovered
# via reflection at boot.
#
module Vouch
  module PasswordTrackable
    module Concern
      extend ActiveSupport::Concern

      included do
        before_validation :lock_password_history, if: :password_digest_changed?
        before_update :lock_password_history, if: :password_digest_changed?
        after_update :archive_password, if: :saved_change_to_password_digest?
        validate :password_not_recently_used, if: :password_digest_changed?
        after_validation :clear_locked_password_digest, if: -> { errors.any? }
        after_rollback :clear_locked_password_digest
      end

      class_methods do
        def password_archive_reflection
          explicit = auth_config(:password_trackable, :association)&.to_sym
          reflections = reflect_on_all_associations(:has_many)
          if explicit
            reflection = reflections.find { |candidate| candidate.name == explicit }
            if reflection && reflection.klass.include?(Vouch::PasswordArchive::Concern)
              return reflection
            end
            raise Vouch::ConfigurationError, "#{name} needs a has_many :#{explicit} targeting a password archive model."
          end
          matches = reflections.select { |candidate| candidate.klass.include?(Vouch::PasswordArchive::Concern) }
          unless matches.one?
            raise Vouch::ConfigurationError, "#{name} needs exactly one password archive association. Set password_trackable: { association: :name }."
          end
          matches.first
        end
      end

      def password_not_recently_used
        return if password.blank?

        if password_reused_against?(@locked_password_digest || password_digest_in_database)
          errors.add(:password, I18n.t("vouch.password_trackable.reused"))
        end
      end

      def archive_password
        digest = @locked_password_digest || password_digest_before_last_save
        return unless digest.present?

        password_archives_relation.create!(password_digest: digest)
        prune_old_password_archives
      ensure
        clear_locked_password_digest
      end

      private

      def lock_password_history
        clear_locked_password_digest
        return unless persisted? && password.present?

        # During save, the enclosing Active Record transaction holds this lock
        # through after_update so the archived digest matches the row that was
        # current immediately before this password change.
        @locked_password_digest = self.class
          .where(Vouch::RecordKey.attributes_for(self))
          .lock
          .pick(:password_digest)
      end

      def password_reused_against?(previous)
        recent_archives = password_archives_relation
          .where("created_at > ?", auth_config(:password_trackable, :history_window).ago)
          .order(created_at: :desc)
          .limit(auth_config(:password_trackable, :history_count))

        reused = previous.present? && BCrypt::Password.new(previous) == password
        reused ||= recent_archives.any? { |archive| BCrypt::Password.new(archive.password_digest) == password }
        reused
      end

      def clear_locked_password_digest
        @locked_password_digest = nil
      end

      def password_archives_relation
        public_send(self.class.password_archive_reflection.name)
      end

      def prune_old_password_archives
        self.class.transaction do
          password_archives_relation
            .where("created_at < ?", auth_config(:password_trackable, :history_window).ago)
            .delete_all

          keep_ids = password_archives_relation.order(created_at: :desc)
                       .limit(auth_config(:password_trackable, :history_count))
                       .pluck(password_archives_relation.klass.primary_key)
          password_archives_relation.where.not(password_archives_relation.klass.primary_key => keep_ids).delete_all if keep_ids.any?
        end
      end
    end
  end
end
