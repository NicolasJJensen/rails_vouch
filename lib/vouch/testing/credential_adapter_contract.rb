# frozen_string_literal: true

module Vouch
  module Testing
    # Optional RSpec shared examples for host-defined two-factor credentials.
    # Requiring this file does not load RSpec. A host opts in from its spec
    # helper with:
    #
    #   require "vouch/testing/credential_adapter_contract"
    #   Vouch::Testing::CredentialAdapterContract.install!
    #
    # The including example group supplies `credential_adapter`. This keeps
    # provider-specific issuance and clock control in the host test suite.
    module CredentialAdapterContract
      SHARED_EXAMPLE_NAME = "a Vouch credential adapter"

      def self.install!(rspec = Object.const_get(:RSpec))
        return if @installed_for.equal?(rspec)

        rspec.shared_examples SHARED_EXAMPLE_NAME do
          it "returns a successful issuance outcome with a usable proof" do
            issuance = credential_adapter.issue

            expect(issuance.outcome).to respond_to(:ok?, :token)
            expect(issuance.outcome).to be_ok
            expect(credential_adapter.verify(issuance)).to be_ok
          end

          it "rejects replay of an accepted proof" do
            issuance = credential_adapter.issue

            expect(credential_adapter.verify(issuance)).to be_ok
            expect(credential_adapter.verify(issuance)).to be_invalid
          end

          it "rejects an invalid proof" do
            issuance = credential_adapter.issue

            expect(credential_adapter.verify(issuance, proof: credential_adapter.invalid_proof)).to be_invalid
          end

          it "rejects a proof after the credential is disabled" do
            issuance = credential_adapter.issue
            credential_adapter.disable!

            expect(credential_adapter.verify(issuance)).to be_locked
          end

          it "rejects a proof after the credential becomes unverified" do
            issuance = credential_adapter.issue
            credential_adapter.unverify!

            expect(credential_adapter.verify(issuance)).to be_locked
          end

          it "rejects an expired proof using the adapter's clock boundary" do
            issuance = credential_adapter.issue

            credential_adapter.after_expiry do
              expect(credential_adapter.verify(issuance)).to be_invalid
            end
          end

          it "rejects the same proof through an instance loaded before acceptance" do
            issuance = credential_adapter.issue
            stale = credential_adapter.stale_credential

            expect(credential_adapter.verify(issuance)).to be_ok
            expect(credential_adapter.verify(issuance, credential: stale)).to be_invalid
          end

          it "does not consume a proof when persistence fails" do
            issuance = credential_adapter.issue

            expect { credential_adapter.verify_with_persistence_failure(issuance) }
              .to raise_error(ActiveRecord::ActiveRecordError)
            expect(credential_adapter.verify(issuance)).to be_ok
          end

          it "returns a cancelled outcome and leaves the proof retryable when persistence is cancelled" do
            issuance = credential_adapter.issue

            credential_adapter.with_cancelled_persistence do
              expect(credential_adapter.verify(issuance)).to be_cancelled
            end
            expect(credential_adapter.verify(issuance)).to be_ok
          end
        end

        @installed_for = rspec
      end
    end
  end
end
