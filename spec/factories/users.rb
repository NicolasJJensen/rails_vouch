# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    account
    organisation

    trait :invited do
      invitation_token { SecureRandom.uuid }
      invitation_sent_at { Time.current }
      after(:build) do |user|
        user.account.update!(registration_required: true) if user.invitation_registration_required?
      end
    end
  end
end
