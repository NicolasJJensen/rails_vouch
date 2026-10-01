require "rails_helper"

RSpec.describe "Password reset transaction boundaries", type: :request do
  self.use_transactional_tests = false

  %i[signed opaque].each do |strategy|
    context strategy.to_s do
      before do
        allow(Account).to receive(:password_reset_strategy).and_return(strategy)
        @account = create(:account, email_address: "reset-transaction-#{SecureRandom.hex(8)}@example.com")
        @cancel_commit = proc { raise ActiveRecord::Rollback }
      end

      after do
        Account.skip_callback(:before_commit, :before, @cancel_commit, raise: false)
        PasswordArchive.where(account_id: @account.id).delete_all
        Account.where(id: @account.id).delete_all
      end

      it "does not deliver a token when the issuance transaction is cancelled before commit" do
        Account.before_commit(&@cancel_commit)
        expect_any_instance_of(Users::PasswordResetsController).not_to receive(:run_hooks)
        allow(Rails.error).to receive(:report)
        post "/users/password_reset", params: { email_address: @account.email_address }
        expect(response).to redirect_to("/users/sign_in")
        expect(@account.reload.password_reset_nonce).to be_nil
        expect(@account.password_reset_token_digest).to be_nil
      end

      it "does not announce password change when its transaction is cancelled before commit" do
        token = @account.generate_password_reset_token!.value
        Account.before_commit(&@cancel_commit)
        expect_any_instance_of(Users::PasswordResetsController).not_to receive(:run_hooks)
        patch "/users/password_reset", params: { token: token, account: { password: "replacement-password" } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(@account.reload.authenticate("password123")).to be_truthy
        expect(Account.find_by_auth_password_reset_token(token)).to eq(@account)
      end

      it "lets only one concurrent consumer change the password" do
        token = @account.generate_password_reset_token!.value
        ready = Queue.new
        start = Queue.new
        threads = 2.times.map do |index|
          Thread.new do
            Account.connection_pool.with_connection do
              record = Account.find(@account.id)
              ready << true
              start.pop
              record.reset_password_with_token(token, password: "replacement-password-#{index}")
            end
          end
        end
        2.times { ready.pop }
        2.times { start << true }
        results = threads.map(&:value)
        expect(results.count(&:ok?)).to eq(1)
        expect(results.count(&:invalid?)).to eq(1)
      end
    end
  end
end
