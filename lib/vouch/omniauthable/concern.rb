# frozen_string_literal: true

# OAuth account linking.
#
# Hosts include this on the Account model alongside Authenticatable. Provides
# `new_from_omniauth` (build a new account from an OmniAuth callback) and
# `update_from_oauth!` (update an existing account after OAuth sign-in).
#
# The default attribute mapping only sets `email_address` when the column
# exists. Override `oauth_attributes_for_creation` or
# `oauth_attributes_for_update` to capture provider-specific fields
# (e.g. avatar_url, name).
#
module Vouch
  module Omniauthable
    module Concern
      extend ActiveSupport::Concern

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

      class_methods do
        # Build an unsaved account; the verified provider supplies its sign-in method.
        def new_from_omniauth(auth_hash)
          new(oauth_attributes_for_creation(auth_hash))
        end

        # Override-tag: host-facing — attributes for a new account from
        # OAuth. Default captures email when the column exists.
        def oauth_attributes_for_creation(auth_hash)
          attrs = {}
          if column_names.include?("email_address") && auth_hash.info.email.present?
            attrs[:email_address] = auth_hash.info.email
          end
          attrs
        end
      end
    end
  end
end
