require "rails_helper"

RSpec.describe "Password reset strategies" do
  %i[signed opaque].each do |strategy|
    context strategy.to_s do
      let(:account) { create(:account) }

      before do
        stub_const("ResetStrategyAccount", Class.new(Account))
        ResetStrategyAccount.authenticates_with :password_resetable,
          password_resetable: { token_strategy: strategy }
      end

      let(:record) { ResetStrategyAccount.find(account.id) }

      it "issues, resolves and consumes a token once" do
        token = record.generate_password_reset_token!.value
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to eq(record)
        expect(record.reset_password_with_token(token, password: "replacement-password")).to be_ok
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to be_nil
      end

      it "revokes an earlier token on reissue and explicit revocation" do
        first = record.generate_password_reset_token!.value
        second = record.generate_password_reset_token!.value
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(first)).to be_nil
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(second)).to eq(record)
        expect(record.clear_password_reset!).to be_ok
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(second)).to be_nil
      end

      it "rejects expired tokens without changing the password" do
        token = record.generate_password_reset_token!.value
        travel 16.minutes do
          expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to be_nil
          expect(record.reset_password_with_token(token, password: "replacement-password")).to be_invalid
        end
        expect(record.reload.authenticate("password123")).to be_truthy
      end

      it "revokes reset links when the baseline recovery destination changes" do
        token = record.generate_password_reset_token!.value
        record.update!(email_address: "replacement@example.com")
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to be_nil
      end

      it "revokes a token issued after an email-editing instance was loaded" do
        stale = ResetStrategyAccount.find(account.id)
        token = record.generate_password_reset_token!.value
        stale.update!(email_address: "replacement@example.com")
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to be_nil
      end

      it "keeps a token usable after password validation fails and retains form errors" do
        token = record.generate_password_reset_token!.value
        result = record.reset_password_with_token(token, password: "replacement-password", password_confirmation: "different")
        expect(result).to be_invalid
        expect(result.metadata[:record]).to eq(record)
        expect(record.errors[:password_confirmation]).to be_present
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to eq(record)
      end

      it "raises the expected failure with the same record in the bang API" do
        expect { record.reset_password_with_token!("invalid", password: "replacement-password") }
          .to raise_error(Vouch::OperationFailed) { |error| expect(error.result.metadata[:record]).to eq(record) }
      end

      it "rolls back destination mutation and revocation together" do
        token = record.generate_password_reset_token!.value
        record.class.transaction do
          record.update!(email_address: "replacement@example.com")
          raise ActiveRecord::Rollback
        end
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to eq(record.reload)
      end

      it "does not fall back to the other strategy" do
        token = record.generate_password_reset_token!.value
        ResetStrategyAccount.authenticates_with :password_resetable,
          password_resetable: { token_strategy: strategy == :signed ? :opaque : :signed }
        expect(ResetStrategyAccount.find_by_auth_password_reset_token(token)).to be_nil
      end

      it "validates only the schema required by the selected strategy" do
        expected = strategy == :signed ? [:password_reset_nonce] : %i[password_reset_token_digest password_reset_sent_at]
        expect(Vouch::FeatureContracts.columns_for(:password_resetable, ResetStrategyAccount)).to eq(expected)
      end
    end
  end
end
