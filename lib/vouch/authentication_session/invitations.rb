# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module Invitations
      def begin_invitation!(identity)
        payload = {
          'user_id' => identity.id.to_s,
          'token' => identity.invitation_token,
          'scope' => scope.to_s
        }
        session[key(:invited_user)] = payload

        mapping = controller.send(:auth_mapping)
        if mapping.membership_scope?
          session[Vouch::Session.key_for(mapping.parent_scope_name, :invited_user)] = payload
        end
      end

      def load_invitation
        payload = session[key(:invited_user)]
        return nil unless payload.is_a?(Hash) && payload['token'].present?

        payload_scope = payload['scope']&.to_sym
        mapping = Vouch.mapping_for(payload_scope || controller.send(:auth_scope_name))
        identity = mapping.identity_class.find_by(mapping.identity_class.primary_key => payload['user_id'])
        return nil unless identity && identity.invitation_token.present? && !identity.invitation_expired? &&
          ActiveSupport::SecurityUtils.secure_compare(identity.invitation_token, payload['token'])

        identity
      end

      def clear_invitation
        payload = session[key(:invited_user)]
        session.delete(key(:invited_user))
        source_scope = payload.is_a?(Hash) && payload['scope']&.to_sym
        session.delete(Vouch::Session.key_for(source_scope, :invited_user)) if source_scope

        mapping = controller.send(:auth_mapping)
        if mapping.membership_scope?
          session.delete(Vouch::Session.key_for(mapping.parent_scope_name, :invited_user))
        end
      end
    end
  end
end
