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
    class InvitationExistsError < StandardError
      attr_reader :invitation

      def initialize(invitation)
        @invitation = invitation
        super("An invitation already exists for this membership")
      end
    end
    class AlreadyJoinedError < InvitationExistsError
      def message
        "This membership has already joined"
      end
    end

    module Concern
      extend ActiveSupport::Concern

      included do
        scope :pending_invitation, -> { where(invitation_accepted_at: nil, invitation_rejected_at: nil).where.not(invitation_token: nil) }
      end

      def invitation_expired?
        return true if invitation_sent_at.blank?

        invitation_sent_at < Vouch.configuration.invitations.expiry.ago
      end

      def accept_invitation
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
        Vouch::Result.ok(self)
      rescue InvitationExpiredError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
        Vouch::Result.invalid(record: self, error: error)
      end

      def accept_invitation!
        result = accept_invitation
        raise Vouch::OperationFailed, result unless result.ok?
        result
      end

      def reject_invitation
        expected_token = invitation_token
        Vouch::Persistence.transaction(self) do
          lock!
          unless expected_token.present? && invitation_token == expected_token && invitation_accepted_at.nil? && !invitation_expired?
            return Vouch::Result.invalid(record: self, reason: :invalid_token)
          end
          Vouch::Persistence.update!(self, invitation_token: nil, invitation_sent_at: nil,
            invitation_rejected_at: Time.current)
        end
        Vouch::Result.ok(self)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
        Vouch::Result.invalid(record: self, error: error)
      end

      def reject_invitation!
        result = reject_invitation
        raise Vouch::OperationFailed, result unless result.ok?
        result
      end

      def reissue_invitation(**options)
        expected_token = invitation_token
        inviter_keys = Array(self.class.reflect_on_association(:inviter).foreign_key).map(&:to_s)
        inviter_changes = changes.slice(*inviter_keys).transform_values(&:last)
        Vouch::Persistence.transaction(self) do
          reload(lock: true)
          unless expected_token.present? && invitation_token == expected_token && invitation_accepted_at.nil?
            raise InvitationExpiredError
          end

          assign_attributes(inviter_changes)
          self.inviter = options[:invited_by] if options.key?(:invited_by)
          Vouch::Persistence.update!(self,
            invitation_token: SecureRandom.uuid,
            invitation_sent_at: Time.current)
        end
        Vouch::Result.ok(self)
      rescue InvitationExpiredError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
        Vouch::Result.invalid(record: self, error: error)
      end

      def reissue_invitation!(**options)
        result = reissue_invitation(**options)
        raise Vouch::OperationFailed, result unless result.ok?
        result
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
        def invite(invited_by: nil, **attributes)
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
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Vouch::Persistence::Cancelled => error
          Vouch::Result.invalid(record: (error.record if error.respond_to?(:record)), error: error)
        end

        def invite!(**attributes, &block)
          result = invite(**attributes, &block)
          raise Vouch::OperationFailed, result unless result.ok?
          result
        end

        def find_by_invitation_token(token)
          return nil if token.blank?
          pending_invitation.find_by(invitation_token: token)
        end
      end
    end
  end
end
