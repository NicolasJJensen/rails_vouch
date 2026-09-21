# frozen_string_literal: true

# Base class for login resolvers.
#
# Subclass and implement `valid?` and `resolve!`. Use `success!` and `fail!`
# to signal outcomes via throw-based control flow.
#
#   class PhoneResolver < Vouch::LoginResolver::Base
#     def valid?(params)
#       params[:phone].present?
#     end
#
#     def resolve!(params, account_class)
#       account = account_class.find_by(phone: params[:phone])
#       account ? success!(account) : fail!
#     end
#   end
#
module Vouch
  module LoginResolver
    class Base
      attr_reader :account

      # Returns true if this resolver can handle the given params.
      def valid?(params)
        raise NotImplementedError, "#{self.class.name} must implement #valid?"
      end

      # Resolve the account from params. Call `success!(account)` or `fail!`
      # to signal the result.
      def resolve!(params, account_class)
        raise NotImplementedError, "#{self.class.name} must implement #resolve!"
      end

      protected

      def success!(account)
        @account = account
        throw(:resolver, :success)
      end

      def fail!
        throw(:resolver, :failure)
      end
    end
  end
end
