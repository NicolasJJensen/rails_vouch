require 'securerandom'
require_relative 'persistence'

module Vouch
  module ChallengeNonce
    extend ActiveSupport::Concern

    class_methods do
      def validate_auth_schema!(*columns)
        columns.each do |column|
          next if columns_hash.key?(column.to_s)
          raise Vouch::SchemaError, "#{name} is missing the #{column} column. Run the feature migration before using authentication."
        end
      end
    end

    private

    def issue_nonce!(column)
      nonce = SecureRandom.hex(32)
      if persisted?
        Vouch::Persistence.transaction(self) do
          lock!
          Vouch::Persistence.update!(self, column => nonce)
        end
      else
        self[column] = nonce
      end
      nonce
    end

    def nonce_matches?(payload, column)
      expected = self[column]
      supplied = payload.is_a?(Hash) && payload['nonce']
      expected.present? && supplied.is_a?(String) &&
        ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
    end
  end
end
