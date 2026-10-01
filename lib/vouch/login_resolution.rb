# Login resolver concern.
#
# Iterates configured resolvers from Vouch.configuration.login_resolvers.
# Each resolver implements `valid?` and `resolve!`, signaling outcomes via
# `success!(account)` and `fail!` (throw-based control flow).
#
# Resolvers are tried in registration order; conflicting accounts are rejected.
#
#   Account.first_by_auth_conditions(params)
#
module Vouch
  module LoginResolution
    extend ActiveSupport::Concern

    class_methods do
      def first_by_auth_conditions(params)
        candidate = nil
        Vouch.configuration.login_resolvers(model: self).each do |resolver|
          next unless resolver.valid?(params)

          result = catch(:resolver) { resolver.resolve!(params, self); nil }
          next unless result == :success
          return nil if candidate && candidate != resolver.account
          candidate = resolver.account
        end
        candidate
      end
    end
  end
end
