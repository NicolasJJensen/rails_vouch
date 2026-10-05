# frozen_string_literal: true

require "rails_helper"

RSpec.describe "documented selected recovery contact", use_transactional_fixtures: false do
  include ActiveJob::TestHelper

  before do
    @connection = ActiveRecord::Base.connection
    @schema = "vouch_contacts_#{Process.pid}"
    @original_path = @connection.schema_search_path
    @connection.execute("CREATE SCHEMA #{@schema}")
    @connection.schema_search_path = "#{@schema}, public"
    @connection.create_table(:contact_users) do |t|
      t.string :password_digest
      t.string :password_reset_nonce
      t.string :password_reset_token_digest
      t.datetime :password_reset_sent_at
      t.timestamps
    end
    @connection.create_table(:contact_emails) do |t|
      t.references :user, null: false, foreign_key: { to_table: :contact_users }
      t.citext :address, null: false
      t.datetime :verified_at
      t.timestamps
    end
    @connection.add_reference :contact_users, :primary_email, foreign_key: { to_table: :contact_emails }
    stub_const("RecoveryContactExample", Module.new)
    guide = File.read(File.expand_path("../../docs/password-reset.md", __dir__))
    blocks = guide.scan(/```ruby\n(.*?)```/m).flatten
    user_source = blocks.find { |code| code.include?("def primary_email_belongs_to_user") }
    email_source = blocks.find { |code| code.include?("def recovery_contact_changed?") }
    RecoveryContactExample.module_eval(user_source.sub("class User < ApplicationRecord", <<~SOURCE))
      class User < ApplicationRecord
        self.table_name = "contact_users"
        include Vouch::Authenticatable
        authenticates_with :password_resetable
        has_secure_password
    SOURCE
    RecoveryContactExample.module_eval(email_source.sub("class Email < ApplicationRecord", "class Email < ApplicationRecord\nself.table_name = 'contact_emails'"))
  end

  after do
    @connection.schema_search_path = @original_path
    @connection.execute("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
  end

  %i[signed opaque].each do |strategy|
    context "with #{strategy} tokens" do
      before do
        RecoveryContactExample::User.authenticates_with :password_resetable,
          password_resetable: { token_strategy: strategy }
      end

      let(:owner) { RecoveryContactExample::User.create!(password: "old-password") }
      let(:email) { owner.emails.create!(address: "original@example.com", verified_at: Time.current) }
      let(:token) do
        owner.update!(primary_email: email)
        owner.generate_password_reset_token!.value
      end

      it "queues the captured recipient and keeps it after a contact change" do
        owner.update!(primary_email: email)
        mailer = Class.new(ActionMailer::Base) do
          self.delivery_method = :test
          default from: "support@example.com"
          def reset(user, token, recipient:)
            mail(to: recipient, subject: "Reset password", body: token)
          end
        end
        stub_const("RecoveryContactExample::Mailer", mailer)
        controller_class = Class.new(Vouch::PasswordResetsController) do
          on_password_reset_token_generation do |user, token, recipient|
            RecoveryContactExample::Mailer.reset(user, token, recipient: recipient).deliver_later
          end
          private
          def password_reset_accounts
            RecoveryContactExample::User.all
          end
          def password_reset_recipient
            @account.emails.where.not(verified_at: nil)
              .find_by(id: @account.primary_email_id)&.address
          end
        end
        controller = controller_class.new
        controller.instance_variable_set(:@vouch_account, owner)
        controller.instance_variable_set(:@account, owner)
        outcome = controller.send(:issue_password_reset)
        expect(outcome).to be_ok
        email.update!(address: "replacement@example.com")
        perform_enqueued_jobs
        expect(ActionMailer::Base.deliveries.last.to).to eq(["original@example.com"])
        expect(ActionMailer::Base.deliveries.last.body.to_s).to include(outcome.value)
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(outcome.value)).to be_nil
      end

      it "rejects selection of a different owner's email" do
        other = RecoveryContactExample::User.create!(password: "other-password")
        expect(other.update(primary_email: email)).to be(false)
        expect(other.errors[:primary_email]).to be_present
      end

      it "revokes on selection change, but leaves unrelated contact updates alone" do
        original_token = token
        other = owner.emails.create!(address: "second@example.com", verified_at: Time.current)
        other.update!(address: "unselected@example.com")
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(original_token)).to eq(owner)
        owner.update!(primary_email: other)
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(original_token)).to be_nil
      end

      it "revokes when the selected address changes or loses verification" do
        original_token = token
        email.update!(address: "new@example.com")
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(original_token)).to be_nil
        next_token = owner.reload.generate_password_reset_token!.value
        email.update!(verified_at: nil)
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(next_token)).to be_nil
      end

      it "revokes and clears selection before ownership transfer or deletion" do
        original_token = token
        other = RecoveryContactExample::User.create!(password: "other-password")
        email.update!(user: other)
        expect(owner.reload.primary_email_id).to be_nil
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(original_token)).to be_nil
        other.update!(primary_email: email)
        other_token = other.generate_password_reset_token!.value
        email.destroy!
        expect(other.reload.primary_email_id).to be_nil
        expect(RecoveryContactExample::User.find_by_auth_password_reset_token(other_token)).to be_nil
      end
    end
  end
end
