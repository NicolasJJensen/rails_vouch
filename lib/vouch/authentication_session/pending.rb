# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module Pending
      PendingAuthenticationContext = Struct.new(:account, :context, keyword_init: true)

      def begin_second_factor!(context, primary: nil)
        renew!
        session[key(:signed_in_via)] = primary if primary
        context['factor_required'] = true
        session[key(:two_factor)] = context
      end

      def load_second_factor
        load_pending(:two_factor)
      end

      def begin_selection!(account, context, primary: nil)
        renew!
        session[key(:signed_in_via)] = primary if primary
        session[key(:selection)] = context
        warden.set_user(account, scope: account_scope, store: true)
      end

      def load_selection
        # The account Warden scope proves this is a tier-2 selection session.
        return nil unless warden.user(account_scope)

        load_pending(:selection)
      end

      private

      def load_pending(purpose)
        context = session[key(purpose)]
        mapping = controller.send(:auth_mapping)
        account = if context.is_a?(Hash)
          begin
            Vouch::RecordKey.find(mapping.account_class.all, context['account_id'])
          rescue ActiveRecord::RecordNotFound, ArgumentError
            nil
          end
        end
        if account && Vouch::PendingAuthentication.valid?(context, account) &&
            controller.send(:authentication_allowed?, account, context)
          PendingAuthenticationContext.new(account: account, context: context)
        else
          session.delete(key(purpose))
          # MFA challenge tokens are invalidated by their controller outcomes.
          warden.logout(account_scope) if purpose == :selection
          nil
        end
      end
    end
  end
end
