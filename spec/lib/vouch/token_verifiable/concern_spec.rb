# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::TokenVerifiable::Concern do
  let(:record) { create(:invitation_link) }

  describe "before_create assigns a nonce" do
    it "populates confirmation_nonce on create" do
      expect(record.confirmation_nonce).to be_present
    end
  end

  describe "#confirmation_token" do
    it "rejects an unpersisted record without creating it" do
      draft = InvitationLink.new(recipient_email: "draft@example.com")

      expect { draft.confirmation_token }
        .to raise_error(ArgumentError, /unpersisted/)
      expect(draft).not_to be_persisted
    end

    it "rejects a destroyed record" do
      record.destroy!

      expect { record.confirmation_token }
        .to raise_error(ArgumentError, /unpersisted/)
    end

    it "returns a signed token that the gem can verify" do
      token   = record.confirmation_token
      payload = InvitationLink.token_verifier.verify(
        token, purpose: InvitationLink.token_purpose_key
      )
      expect(payload["id"] || payload[:id]).to eq(record.id)
      expect(payload["nonce"] || payload[:nonce]).to eq(record.confirmation_nonce)
    end

    it "is unique across rows" do
      other = create(:invitation_link)
      expect(record.confirmation_token).not_to eq(other.confirmation_token)
    end
  end

  describe ".consume_token" do
    it "verifies the record and rotates the nonce" do
      token         = record.confirmation_token
      previous_nonce = record.confirmation_nonce

      consumed = InvitationLink.consume_token(token)

      expect(consumed).to be_ok
      expect(consumed.value.verified_at).to be_present
      expect(consumed.value.reload.confirmation_nonce).not_to eq(previous_nonce)
    end

    it "uses a single UPDATE for verify + rotate" do
      token = record.confirmation_token
      queries = capture_sql { InvitationLink.consume_token(token) }
      updates = queries.select { |q| q.match?(/\AUPDATE/i) }
      expect(updates.length).to eq(1)
    end

    it "returns nil on a replayed token" do
      token = record.confirmation_token
      InvitationLink.consume_token(token)
      expect(InvitationLink.consume_token(token)).to be_invalid
    end

    it "returns nil on a tampered token" do
      token = record.confirmation_token + "abc"
      expect(InvitationLink.consume_token(token)).to be_invalid
    end

    it "returns invalid for a non-string token" do
      [nil, 123, {}, []].each do |token|
        expect(InvitationLink.consume_token(token)).to be_invalid
      end
    end

    it "returns nil on a token signed for a different purpose" do
      verifier = Rails.application.message_verifier(:wrong_purpose)
      token    = verifier.generate(
        { id: record.id, nonce: record.confirmation_nonce },
        expires_in: 1.day,
        purpose:    :wrong_purpose
      )
      expect(InvitationLink.consume_token(token)).to be_invalid
    end

    it "returns nil on an expired token" do
      token = record.confirmation_token
      travel_to((InvitationLink.token_validity + 1.hour).from_now) do
        expect(InvitationLink.consume_token(token)).to be_invalid
      end
    end

    it "returns nil when the row was deleted" do
      token = record.confirmation_token
      record.destroy!
      expect(InvitationLink.consume_token(token)).to be_invalid
    end
  end

  describe "#rotate_confirmation_nonce!" do
    it "invalidates any outstanding token" do
      token = record.confirmation_token
      record.rotate_confirmation_nonce!
      expect(InvitationLink.consume_token(token)).to be_invalid
    end
  end

  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
