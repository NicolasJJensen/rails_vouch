# frozen_string_literal: true

class User < ApplicationRecord
  include Vouch::Invitable::Concern

  belongs_to :account
  belongs_to :organisation
  belongs_to :inviter,  class_name: "User", optional: true
  has_many   :invitees, class_name: "User", foreign_key: :inviter_id, dependent: :nullify

  delegate :email_address, :locked?, :two_factor_enabled?, to: :account
end
