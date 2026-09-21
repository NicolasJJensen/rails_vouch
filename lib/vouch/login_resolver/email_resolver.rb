# frozen_string_literal: true

# Resolves accounts by email address.
#
# Checks `email_address`, `login`, and `email` param keys.
# Email format validation is the host app's responsibility.
#
#   config.register_login_resolver Vouch::LoginResolver::EmailResolver
#
module Vouch
  module LoginResolver
    class EmailResolver < Base
      def valid?(params)
        extract_email(params).present?
      end

      def resolve!(params, account_class)
        email = extract_email(params)
        account = account_class.find_by("lower(email_address) = ?", email.to_s.downcase)
        account ? success!(account) : fail!
      end

      private

      def extract_email(params)
        params[:email_address] || params[:login] || params[:email]
      end
    end
  end
end
