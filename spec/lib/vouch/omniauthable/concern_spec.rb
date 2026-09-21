# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Omniauthable::Concern do
  let(:account) { create(:account) }

  describe "associations" do
    it "has_many :omni_auth_identities" do
      expect(account).to respond_to(:omni_auth_identities)
    end

    it "destroys omni_auth_identities on account deletion" do
      account.omni_auth_identities.create!(provider: "google", uid: "123")
      expect { account.destroy }.to change(OmniAuthIdentity, :count).by(-1)
    end
  end

end
