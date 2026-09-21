# frozen_string_literal: true

FactoryBot.define do
  factory :omni_auth_identity do
    account
    provider { "google_oauth2" }
    sequence(:uid) { |n| "oauth_uid_#{n}" }
  end
end
