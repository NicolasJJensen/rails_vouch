# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    account
    organisation

    trait :invited do
      invitation_token { SecureRandom.uuid }
      invitation_sent_at { Time.current }
    end
  end
end
