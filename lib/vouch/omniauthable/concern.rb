# frozen_string_literal: true

# OAuth account linking.
#
# Registration mapping runs once per newly verified provider, on the restored
# account instance. Sign-in profile updates use a separate mapping.
#
module Vouch
  module Omniauthable
    module Concern
      extend ActiveSupport::Concern

      def apply_oauth_registration(_oauth_identity, auth_hash:)
        if respond_to?(:email_address=) && email_address.blank? && auth_hash.info.email.present?
          self.email_address = auth_hash.info.email
        end
      end

      def update_from_oauth!(auth_hash)
        attrs = oauth_attributes_for_update(auth_hash)
        Vouch::Persistence.update!(self, attrs) if attrs.any?
      end

      # Override-tag: host-facing — attributes to update on an existing
      # account after a fresh OAuth callback. Default backfills email only
      # when missing.
      def oauth_attributes_for_update(auth_hash)
        return {} unless respond_to?(:email_address=) && email_address.blank?
        return {} if auth_hash.info.email.blank?
        { email_address: auth_hash.info.email }
      end

    end
  end
end
