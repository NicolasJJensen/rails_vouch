# frozen_string_literal: true

class OmniAuthIdentity < ApplicationRecord
  include Vouch::OAuthIdentity::Concern

  belongs_to :account
end
