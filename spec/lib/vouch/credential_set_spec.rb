# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::CredentialSet do
  let(:account) do
    create(:account, email_address: "set@example.com",
                     password: "password123",
                     password_confirmation: "password123")
  end

  let(:tfc_assoc) do
    Account.reflect_on_all_associations(:has_many).find { |a| a.klass == TwoFactorCredential }
  end

  describe "single-association config" do
    subject(:set) { described_class.new(account, [tfc_assoc]) }

    let!(:enabled_cred) do
      account.two_factor_credentials.create!(
        otp_secret: SecureRandom.hex(20),
        verified_at: Time.current,
        two_factor_enabled_at: Time.current
      )
    end

    let!(:disabled_cred) do
      account.two_factor_credentials.create!(
        otp_secret: SecureRandom.hex(20),
        verified_at: Time.current
      )
    end

    it "iterates every credential" do
      expect(set.to_a).to match_array([enabled_cred, disabled_cred])
    end

    describe "#reject" do
      it "hides matching records from iteration" do
        filtered = set.reject { |c| c.id == enabled_cred.id }
        expect(filtered.to_a).to eq([disabled_cred])
      end

      it "hides matching records from find (bare-id path)" do
        filtered = set.reject { |c| c.id == enabled_cred.id }
        expect { filtered.find(enabled_cred.id) }
          .to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns a new instance — original is unchanged" do
        filtered = set.reject { |c| c.id == enabled_cred.id }
        expect(set.to_a.length).to eq(2)
        expect(filtered.to_a.length).to eq(1)
      end

      it "composes with .enabled" do
        expect(set.enabled.reject { |c| c.id == enabled_cred.id }.to_a).to be_empty
      end

      it "reflects the filter in count/size/length" do
        filtered = set.reject { |c| c.id == enabled_cred.id }
        expect(filtered.count).to eq(1)
      end

      it "raises without a block" do
        expect { set.reject }.to raise_error(ArgumentError, /block/)
      end
    end

    it "scopes by .enabled" do
      expect(set.enabled.to_a).to eq([enabled_cred])
    end

    it "chains .enabled.find" do
      expect(set.enabled.find(enabled_cred.id)).to eq(enabled_cred)
    end

    it "finds a credential by bare id (back-compat for single-assoc hosts)" do
      expect(set.find(enabled_cred.id)).to eq(enabled_cred)
    end

    it "finds a letter-leading opaque id for a single association" do
      uuid = "a7f0c8d1-3b2e-4f65-9012-abcdef123456"
      record = double("TwoFactorCredential", id: uuid)
      relation = double("TwoFactorCredentialsRelation")
      allow(account).to receive(:two_factor_credentials).and_return(relation)
      allow(relation).to receive(:find_by).with("id" => uuid).and_return(record)

      expect(set.find(uuid)).to eq(record)
    end

    it "finds a credential by typed param (kind-id format)" do
      kind = TwoFactorCredential.model_name.singular
      expect(set.find("#{kind}-#{enabled_cred.id}")).to eq(enabled_cred)
    end

    it "raises ActiveRecord::RecordNotFound on a missing id" do
      expect { set.find(0) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ActiveRecord::RecordNotFound on an unknown kind" do
      expect { set.find("imaginary-1") }.to raise_error(ActiveRecord::RecordNotFound, /imaginary/)
    end

    it "delegates .new to the single association" do
      built = set.new(otp_secret: "abc")
      expect(built).to be_a(TwoFactorCredential)
      expect(built.account).to eq(account)
      expect(built.otp_secret).to eq("abc")
    end

    it "raises on a blank param" do
      expect { set.find("") }.to raise_error(ActiveRecord::RecordNotFound)
      expect { set.find(nil) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "reports size/length/count by walking relations" do
      expect(set.size).to eq(2)
      expect(set.length).to eq(2)
      expect(set.count).to eq(2)
    end

    it "reports empty? when no records exist" do
      empty_account = create(:account, email_address: "empty@example.com",
                                       password: "password123",
                                       password_confirmation: "password123")
      expect(described_class.new(empty_account, [tfc_assoc])).to be_empty
    end
  end

  describe "multi-association config" do
    # Simulate a second TwoFactorable-bearing association by re-using the
    # same TwoFactorCredential class under a different reflection. The
    # behaviour under test is dispatch-by-kind and cross-relation iteration,
    # not table layout, so reflection identity is enough.
    let(:second_assoc) do
      double(
        "Reflection",
        name: tfc_assoc.name,
        klass: TwoFactorCredential
      )
    end

    subject(:set) { described_class.new(account, [tfc_assoc, second_assoc]) }

    let!(:credential) do
      account.two_factor_credentials.create!(
        otp_secret: SecureRandom.hex(20),
        verified_at: Time.current,
        two_factor_enabled_at: Time.current
      )
    end

    it "raises NoMethodError on .new (ambiguous)" do
      expect { set.new(otp_secret: "abc") }.to raise_error(NoMethodError, /ambiguous/)
    end

    it "raises when a typed kind is ambiguous across associations" do
      kind = TwoFactorCredential.model_name.singular
      expect { set.find("#{kind}-#{credential.id}") }
        .to raise_error(Vouch::ConfigurationError, /ambiguous/)
    end

    it "resolves a known kind before parsing a letter-leading UUID" do
      uuid = "a7f0c8d1-3b2e-4f65-9012-abcdef123456"
      phone_kind = double("PhoneCredential", singular: "phone")
      phone_class = double("PhoneCredentialClass", model_name: phone_kind, primary_key: "id")
      phone_assoc = double("PhoneReflection", name: :two_factor_credentials, klass: phone_class)
      phone = double("PhoneCredential", id: uuid)
      phones = double("PhonesRelation")
      allow(account).to receive(:two_factor_credentials).and_return(phones)
      allow(phones).to receive(:find).with(uuid).and_return(phone)

      expect(described_class.new(account, [phone_assoc, tfc_assoc]).find("phone-#{uuid}")).to eq(phone)
    end

    it "falls back to the full opaque id when a kind-looking prefix is unknown" do
      uuid = "a7f0c8d1-3b2e-4f65-9012-abcdef123456"
      email_kind = double("EmailCredential", singular: "email")
      email_class = double("EmailCredentialClass", model_name: email_kind, primary_key: "id")
      email_assoc = double("EmailReflection", name: :two_factor_credentials, klass: email_class)
      email = double("EmailCredential", id: uuid)
      emails = double("EmailsRelation")
      allow(account).to receive(:two_factor_credentials).and_return(emails)
      allow(emails).to receive(:find_by).with("id" => uuid).and_return(email)

      expect(described_class.new(account, [email_assoc, tfc_assoc]).find(uuid)).to eq(email)
    end

    it "exposes the underlying association reflections" do
      expect(set.associations).to eq([tfc_assoc, second_assoc])
    end
  end
end
