# Credential adapter contract

Vouch includes optional RSpec shared examples for a custom two-factor
credential. Use this guide when your credential has its own challenge and
delivery implementation but should satisfy the same replay, lockout, expiry,
and persistence guarantees as Vouch credentials.

The contract is test support only. It does not load RSpec at runtime or add it
to the gem's dependencies.

## Contents

- [Install the shared examples](#install-the-shared-examples)
- [Minimal adapter interface](#minimal-adapter-interface)
- [What the contract checks](#what-the-contract-checks)

## Install the shared examples

Load the contract from your application's spec helper:

```ruby
# spec/rails_helper.rb
require "vouch/testing/credential_adapter_contract"

Vouch::Testing::CredentialAdapterContract.install!
```

Define the adapter below in `spec/support/phone_credential_adapter.rb` and require it from `spec/rails_helper.rb`. Then use it in `spec/models/phone_spec.rb`:

```ruby
# spec/models/phone_spec.rb
RSpec.describe Phone do
  let(:credential_adapter) { PhoneCredentialAdapter.new(self) }

  it_behaves_like "a Vouch credential adapter"
end
```

This example uses the `Phone` model from the MFA guide and a `:phone` factory that supplies its owner and phone number. The adapter wraps one persisted, verified, enabled credential. Keep provider-specific
setup and time control inside the adapter so the shared examples can exercise
different delivery protocols.

For example, define the factory with its real owner association:

```ruby
# spec/factories/phones.rb
FactoryBot.define do
  factory :phone do
    association :user
    sequence(:e164) { |number| "+614#{number.to_s.rjust(8, '0')}" }
  end
end
```

## Minimal adapter interface

The shared examples call these methods:

```ruby
# spec/support/phone_credential_adapter.rb
class PhoneCredentialAdapter
  Issuance = Struct.new(:outcome, :proof)
  include ActiveSupport::Testing::TimeHelpers

  attr_reader :credential

  def initialize(example)
    @credential = example.create(:phone, verified_at: Time.current, two_factor_enabled_at: Time.current)
  end

  def issue
    proof = nil
    credential.define_singleton_method(:deliver_two_factor_code) { |code| proof = code }
    Issuance.new(credential.challenge, proof)
  end

  def verify(issuance, credential: self.credential, proof: issuance.proof)
    credential.verify_challenge(proof, token: issuance.outcome.token)
  end

  def verify!(issuance, proof: issuance.proof)
    credential.verify_challenge!(proof, token: issuance.outcome.token)
  end

  def invalid_proof
    "invalid-proof"
  end

  def disable!
    credential.disable_two_factor!
  end

  def unverify!
    credential.unverify!
  end

  def after_expiry(&block)
    travel(credential.user.auth_config(:two_factorable, :challenge_validity) + 1.second, &block)
  end

  def maximum_attempts
    credential.user.auth_config(:two_factorable, :max_attempts)
  end

  def stale_credential
    credential.class.find(credential.id)
  end

  def verify_with_persistence_failure(issuance)
    failing = credential.class.find(credential.id)
    failing.define_singleton_method(:update!) do |*|
      raise ActiveRecord::ActiveRecordError, "simulated persistence failure"
    end
    verify(issuance, credential: failing)
  end

  def with_cancelled_persistence
    target_id = credential.id
    callback = proc { raise ActiveRecord::Rollback if id == target_id }
    credential.class.set_callback(:update, :before, callback)
    yield
  ensure
    credential.class.skip_callback(:update, :before, callback)
  end
end
```

The actual `issue` implementation must return an object with `outcome` and
`proof`. `outcome` must respond to `ok?` and `token`; `proof` is the value
submitted by `verify`. `verify` returns a `Vouch::Result` with statuses such as
`ok?`, `invalid?`, `locked?`, and `cancelled?`.

`after_expiry` must run its block after the provider's validity boundary. A
TOTP adapter must advance beyond its entire accepted drift window, not just
the next time step. For a 30-second interval with 30 seconds of drift in each
direction, advance 91 seconds. An OTP adapter uses the credential owner’s
configured challenge validity, which can differ from the global default. `stale_credential` must return a
separately loaded instance of the same row.

## What the contract checks

The shared examples verify that the adapter:

- issues a usable proof;
- rejects invalid, expired, and replayed proofs;
- locks verification after the owner’s configured attempt limit;
- rejects a proof after disablement or unverification;
- rejects a proof through an instance loaded before acceptance;
- preserves the proof when persistence raises an Active Record error; and
- returns `cancelled` and preserves the proof when acceptance is rolled back.

Unexpected database errors propagate to your application. A cancelled acceptance
returns `Vouch::Result.cancelled`, and the same proof remains retryable after
the cancellation condition is removed.

See
[`spec/lib/vouch/testing/credential_adapter_contract_spec.rb`](../spec/lib/vouch/testing/credential_adapter_contract_spec.rb)
for complete OTP and TOTP adapters.

These are model-level checks. They do not exercise HTTP rate limits, the
controller’s binding of a challenge to the credential’s current enabled period,
or competing database transactions. Keep request tests for your authentication
flow and concurrency tests for adapters that implement their own persistence.

The example uses the concrete `Phone#user` association from the MFA guide.
Replace that association in the adapter if your credentials belong to another
model. `unverify!` deliberately exercises Vouch’s revocation callbacks instead
of clearing `verified_at` directly. The temporary callback used by the rollback
example affects only the test credential and is removed even when the test fails.
