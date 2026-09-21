# frozen_string_literal: true

class InvitationLink < ApplicationRecord
  include Vouch::TokenVerifiable::Concern

  validates :recipient_email, presence: true
end
