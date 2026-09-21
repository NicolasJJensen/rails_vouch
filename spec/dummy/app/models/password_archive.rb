# frozen_string_literal: true

class PasswordArchive < ApplicationRecord
  include Vouch::PasswordArchive::Concern

  belongs_to :account
end
