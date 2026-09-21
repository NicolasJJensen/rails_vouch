# frozen_string_literal: true

FactoryBot.define do
  factory :invitation_link do
    sequence(:recipient_email) { |n| "invitee#{n}@example.com" }
  end
end
