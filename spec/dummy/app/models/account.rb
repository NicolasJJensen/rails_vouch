# frozen_string_literal: true

class Account < ApplicationRecord
  include Vouch::Authenticatable

  authenticates_with :lockable, :password_resetable, :password_trackable,
                     :two_factorable, :omniauthable, :recoverable

  has_secure_password

  validates :email_address, presence: true,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }
  validates :password, on: [:registration, :password_change],
    presence: true,
    length: { minimum: 8, maximum: 72 }

  before_validation { self.email_address = email_address&.strip&.downcase }

  has_many :users, dependent: :destroy
  has_many :organisations, through: :users

  has_many :omni_auth_identities, dependent: :destroy
  has_many :two_factor_credentials, dependent: :destroy
  has_many :password_archives, -> { order(created_at: :desc) }, dependent: :destroy

end
