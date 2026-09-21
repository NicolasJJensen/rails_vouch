# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module Invitations
      def begin_invitation!(identity)
        session[key(:invited_user)] = {
          'user_id' => identity.id.to_s,
          'token' => identity.invitation_token
        }
      end

      def load_invitation
        payload = session[key(:invited_user)]
        return nil unless payload.is_a?(Hash) && payload['token'].present?

        mapping = controller.send(:auth_mapping)
        identity = mapping.identity_class.find_by(mapping.identity_class.primary_key => payload['user_id'])
        return nil unless identity && identity.invitation_token.present? && !identity.invitation_expired? &&
          ActiveSupport::SecurityUtils.secure_compare(identity.invitation_token, payload['token'])

        identity
      end

      def clear_invitation
        session.delete(key(:invited_user))
      end
    end
  end
end
