# frozen_string_literal: true

require "rails_helper"
require "vouch/testing/credential_adapter_contract"

Vouch::Testing::CredentialAdapterContract.install!

RSpec.describe Vouch::Testing::CredentialAdapterContract do
  Issuance = Struct.new(:outcome, :proof)

  class ContractAdapter
    include ActiveSupport::Testing::TimeHelpers

    attr_reader :credential

    def initialize(example, protocol:)
      @example = example
      @protocol = protocol
      @credential = example.create(:account).two_factor_credentials.create!(
        type: protocol.to_s,
        otp_secret: protocol == :totp ? ROTP::Base32.random : nil,
        verified_at: Time.current,
        two_factor_enabled_at: Time.current
      )
    end

    def issue
      if @protocol == :totp
        Issuance.new(credential.challenge!, ROTP::TOTP.new(credential.otp_secret).now)
      else
        proof = nil
        credential.define_singleton_method(:deliver_two_factor_code) { |code| proof = code }
        outcome = credential.challenge!
        Issuance.new(outcome, proof)
      end
    end

    def verify(issuance, credential: self.credential, proof: issuance.proof)
      credential.verify_challenge(proof, token: issuance.outcome.token)
    end

    def invalid_proof
      "invalid-proof"
    end

    def disable!
      credential.disable_two_factor!
    end

    def unverify!
      credential.update!(verified_at: nil)
    end

    def after_expiry(&block)
      duration = if @protocol == :totp
        2.minutes
      else
        Vouch.configuration.two_factorable.challenge_validity + 1.second
      end
      travel(duration, &block)
    end

    def stale_credential
      TwoFactorCredential.find(credential.id)
    end

    def verify_with_persistence_failure(issuance)
      failing = TwoFactorCredential.find(credential.id)
      failing.define_singleton_method(:update!) do |*|
        raise ActiveRecord::ActiveRecordError, "simulated host persistence failure"
      end
      verify(issuance, credential: failing)
    end

    def with_cancelled_persistence
      callback = :rollback_credential_contract_persistence
      TwoFactorCredential.define_method(callback) { raise ActiveRecord::Rollback }
      TwoFactorCredential.set_callback(:update, :before, callback)
      yield
    ensure
      TwoFactorCredential.skip_callback(:update, :before, callback)
      TwoFactorCredential.remove_method(callback)
    end
  end

  context "with the bundled courier OTP protocol" do
    let(:credential_adapter) { ContractAdapter.new(self, protocol: :otp) }

    it_behaves_like "a Vouch credential adapter"
  end

  context "with the dummy host TOTP protocol" do
    let(:credential_adapter) { ContractAdapter.new(self, protocol: :totp) }

    it_behaves_like "a Vouch credential adapter"
  end
end
