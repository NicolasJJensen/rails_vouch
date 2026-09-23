# Credential adapter contract

Vouch provides optional RSpec shared examples for testing host-defined
two-factor credential adapters. The contract is test support only. Requiring it
does not load RSpec or add RSpec as a runtime dependency.

Load and install the shared examples from the host application's spec helper:

```ruby
require "vouch/testing/credential_adapter_contract"

Vouch::Testing::CredentialAdapterContract.install!
```

In the credential spec, provide a `credential_adapter` and include the shared
example:

```ruby
RSpec.describe AuthenticatorCredential do
  let(:credential_adapter) { AuthenticatorCredentialTestAdapter.new(self) }

  it_behaves_like "a Vouch credential adapter"
end
```

The test adapter is deliberately small and provider-specific. It translates the
host credential's issuance and proof protocol into these methods:

- `issue` returns an object with `outcome` and `proof`. `outcome` responds to
  `ok?` and `token`; `proof` is the value submitted during verification.
- `verify(issuance, credential: ..., proof: ...)` submits the proof and returns
  `true` or `false`. The keyword defaults should use the adapter's current
  credential and `issuance.proof`.
- `invalid_proof` returns a proof that the provider must reject.
- `disable!` disables the current credential.
- `unverify!` makes the current credential unverified.
- `after_expiry { ... }` runs the block after the provider's configured expiry
  boundary. The host controls time travel because courier OTP and TOTP have
  different clocks and validity rules.
- `stale_credential` returns a separately loaded instance of the same persisted
  credential.
- `verify_with_persistence_failure(issuance)` simulates an unexpected database
  error while accepting a valid proof.
- `with_cancelled_persistence { ... }` cancels the acceptance transaction, such
  as by raising `ActiveRecord::Rollback`, while the block verifies the proof.

The shared examples require successful issuance and proof, invalid-proof
rejection, replay protection, disabled and unverified rejection, expiry,
stale-instance replay protection, and safe persistence behavior.

A cancelled acceptance returns `false`. Its state changes are rolled back, so
the same valid proof remains retryable after the cancellation condition is
removed. Unexpected database errors propagate to the host instead of being
reported as an invalid proof; the proof also remains retryable after the error
is resolved.

See
[`spec/lib/vouch/testing/credential_adapter_contract_spec.rb`](../spec/lib/vouch/testing/credential_adapter_contract_spec.rb)
for concrete adapters covering the bundled courier OTP path and the dummy host
TOTP path.
