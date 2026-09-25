# frozen_string_literal: true

# Invitation-based onboarding.
#
# Provides a class method `invite!` on the identity model. The inviter
# creates an invitation; the invitee clicks the link and registers. Tokens
# expire after `Vouch.configuration.invitations.expiry`.
#
# Required columns on the identity model:
#   - invitation_token (string, indexed)
#   - invitation_sent_at (datetime)
#   - invitation_accepted_at (datetime)
#   - inviter_id (bigint, optional FK)
#
# The inviter/invitees relationships are intentionally NOT declared here.
# Hosts declare them on their identity model so column names and dependent
# behaviour stay under host control:
#
#   class <IdentityModel> < ApplicationRecord
#     include Vouch::Invitable::Concern
#     belongs_to :inviter,  class_name: "<IdentityModel>", optional: true
#     has_many   :invitees, class_name: "<IdentityModel>",
#                foreign_key: :inviter_id, dependent: :nullify
#   end
#
# Usage:
#   result = <IdentityModel>.invite!(invited_by: current_user) do |invitee|
#     invitee.account = build_invited_account("new@example.com")
#     invitee.<tenant_association> = current_user.<tenant_association>
#   end
#   invitee = result.value
#
module Vouch
  module Invitable
    class InvitationExpiredError < StandardError; end

    module Concern
      extend ActiveSupport::Concern

      included do
        scope :pending_invitation, -> { where.not(invitation_token: nil) }
      end

      def invitation_expired?
        return true if invitation_sent_at.blank?

        invitation_sent_at < Vouch.configuration.invitations.expiry.ago
      end

      def accept_invitation!
        expected_token = invitation_token
        raise InvitationExpiredError if expected_token.blank?

        Vouch::Persistence.transaction(self) do
          lock!
          unless invitation_token == expected_token && !invitation_expired?
            raise InvitationExpiredError
          end

          Vouch::Persistence.update!(self,
            invitation_token:       nil,
            invitation_sent_at:     nil,
            invitation_accepted_at: Time.current
          )
        end
      end

      def reissue_invitation!(invited_by: nil)
        Vouch::Persistence.transaction(self) do
          lock!
          return self unless invitation_token.present? && invitation_accepted_at.nil?

          Vouch::Persistence.update!(self,
            invitation_token: SecureRandom.uuid,
            invitation_sent_at: Time.current,
            inviter: invited_by)
        end
        self
      end

      class_methods do
        # Create an invitation for a new identity.
        #
        # Use the block to set up the invitee's associations:
        #
        #   result = <IdentityModel>.invite!(invited_by: current_user) do |invitee|
        #     invitee.account = build_invited_account("new@example.com")
        #     invitee.<tenant_association> = current_user.<tenant_association>
        #   end
        #   invitee = result.value
        #
        def invite!(invited_by: nil, **attributes)
          token = SecureRandom.uuid

          invitee = new(
            invitation_token:   token,
            invitation_sent_at: Time.current,
            inviter:            invited_by,
            **attributes
          )

          Vouch::Persistence.transaction(invitee) do
            yield invitee if block_given?

            Vouch::Persistence.save!(invitee)
            Vouch::Result.ok(invitee)
          end
        end

        def find_by_invitation_token(token)
          return nil if token.blank?
          find_by(invitation_token: token)
        end
      end
    end
  end
end
