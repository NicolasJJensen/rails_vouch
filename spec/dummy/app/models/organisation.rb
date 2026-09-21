# frozen_string_literal: true

class Organisation < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :accounts, through: :users

  validates :name, presence: true
end
