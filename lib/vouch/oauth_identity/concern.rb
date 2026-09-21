# frozen_string_literal: true

# Shared behaviour for OAuth identity models.
#
# Provides validations and a `from_omniauth` finder so controllers don't
# construct identities directly. Hosts can override the attribute mapping
# by overriding `oauth_attributes` on the subclass.
#
# The host app's model must declare:
#   belongs_to :account
#   encrypts :auth_data (optional)
#
# Required columns: account_id, provider, uid, auth_data
#
# Usage:
#   class OmniAuthIdentity < ApplicationRecord
#     include Vouch::OAuthIdentity::Concern
#     belongs_to :account
#     encrypts :auth_data
#   end
#
module Vouch
  module OAuthIdentity
    module Concern
      extend ActiveSupport::Concern

      included do
        validates :provider, presence: true
        validates :uid, presence: true, uniqueness: { scope: :provider }
      end

      class_methods do
        # Find an existing identity for the provider/uid in `auth_hash`,
        # or return nil. Controllers use this to decide between sign-in
        # and account-creation paths.
        def find_from_omniauth(auth_hash)
          find_by(provider: auth_hash.provider, uid: auth_hash.uid)
        end

        # Build (without saving) a new identity for `auth_hash`. Hosts can
        # override `oauth_attributes` to add extra columns.
        def build_from_omniauth(auth_hash, account: nil, oauth_account_association: nil)
          record = new(oauth_attributes(auth_hash))
          if account
            owner = oauth_account_association || oauth_account_association_for(account)
            record.public_send(:"#{owner.name}=", account)
          end
          record
        end

        def oauth_account_association_for(account)
          candidates = reflect_on_all_associations(:belongs_to).select do |reflection|
            reflection.polymorphic? || account.is_a?(reflection.klass)
          rescue NameError
            false
          end

          if candidates.length != 1
            names = candidates.map(&:name).join(", ")
            detail = names.present? ? " Matching associations: #{names}." : ""
            raise Vouch::ConfigurationError, <<~MSG.squish
              #{name} cannot determine which belongs_to owns #{account.class.name}.#{detail}
              Configure an unambiguous OAuth account association.
            MSG
          end

          candidates.first
        end

        # Override-tag: host-facing — attributes used when building a new
        # OAuth identity from an OmniAuth callback. The default retains only
        # the metadata safe to carry through an authentication continuation;
        # hosts that explicitly need provider credentials can override this
        # method and add their own storage.
        def oauth_attributes(auth_hash)
          metadata = auth_hash.to_h.slice("provider", "uid", "info")
          {
            provider:  metadata["provider"],
            uid:       metadata["uid"],
            auth_data: metadata.to_json
          }
        end
      end
    end
  end
end
