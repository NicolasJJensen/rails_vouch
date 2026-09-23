# frozen_string_literal: true

module Vouch
  class AuthenticationSession
    module Rotation
      def reset_with_preserved_keys
        mapping = controller.send(:auth_mapping)
        affected = [mapping] + Vouch.dependent_mappings(scope)
        preserved = scoped_keys + [key(:impersonation)]

        affected.each do |current|
          owned = [current.scope_name]
          owned << current.account_scope_name unless current.membership_scope?
          owned << :"#{current.scope_name}_impersonation" unless mapping.membership_scope?
          warden.logout(*owned)
          rails_session.keys.each do |name|
            next unless Vouch::Session.state_key?(name, current.scope_name)
            next if current.scope_name == scope && preserved.include?(name.to_s)

            rails_session.delete(name)
          end
        end

        # MFA may start before Warden stores an identity, so request renewal
        # here too. Renewal replaces the identifier without clearing app data.
        options = rails_session.options if rails_session.respond_to?(:options)
        options ||= controller.request.session_options if controller.request
        options[:renew] = true if options
      end
    end
  end
end
