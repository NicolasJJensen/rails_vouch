# Login resolver concern.
#
# Iterates registered resolvers from Vouch.configuration.login_resolvers.
# Each resolver implements `valid?` and `resolve!`, signaling outcomes via
# `success!(account)` and `fail!` (throw-based control flow).
#
# Resolvers are tried in registration order; first match wins.
#
#   Account.first_by_auth_conditions(params)
#
module Vouch
  module LoginResolution
    extend ActiveSupport::Concern

    class_methods do
      def first_by_auth_conditions(params)
        Vouch.configuration.login_resolvers.each do |resolver|
          next unless resolver.valid?(params)

          result = catch(:resolver) { resolver.resolve!(params, self); nil }
          return resolver.account if result == :success
        end
        nil
      end
    end
  end
end
