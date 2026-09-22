# Verification and multi-factor authentication

Vouch supplies challenge state and policy seams but no TOTP dependency. Start with the [README](../README.md); see [passwords and recovery](passwords-and-recovery.md) and [persistence](persistence.md) for proof and transaction behavior.

## Credential concerns

Add `rotp` only for TOTP. Include `Verifiable` on credentials that must be confirmed and declare their natural subject:

```ruby
class Phone < ApplicationRecord
  include Vouch::Verifiable
  include Vouch::TwoFactorable
  include Vouch::MagicLinkable
  self.verifiable_subject_attribute = :e164
  belongs_to :account

  def deliver_verification_code(code) = SmsCourier.send(e164, code)
end
```

Generators add required fields: Verifiable needs `verification_version` and `verification_nonce`; MagicLinkable needs `sign_in_nonce`; TwoFactorable needs `two_factor_nonce`. These nullable string nonces belong to credential rows. Keep feature timestamps and counters. Schema checks run when a feature is used, so class loading does not block migrations.

```ruby
result = phone.start_verification!
session[verification_key] = result.token if result.ok?
phone.complete_verification!(params[:code], token: session[verification_key])
phone.enable_two_factor!
```

Subject changes clear verification and advance its version. Tokens bind subject and version; changing A to B and back to A cannot revive an old token. Successful verification rechecks the current row under its lock. Each persisted challenge is single-use. Issuance retires the previous challenge even when delivery fails. Unrelated updates do not invalidate challenges. Verification, sign-in, and MFA use separate nonces. `unverify!` clears verification and outstanding nonces. Normal model writes are required for invalidation; callback-bypassing writes must do it explicitly.

Unsaved drafts verify in memory and later persist with their account. Editing a verified draft invalidates it. Draft lockout and nonce consumption remain in memory until persistence, so hosts must protect draft session state and rate-limit requests. Persisted replay protection does not apply to restored unsaved drafts.

## Challenge results and account MFA

`challenge!` returns `Result.ok(token)` or `Result.locked`. `verify_challenge(code, token:)` returns a result with `ok?`, `invalid?`, `locked?`, and `cancelled?`. Disabled or unverified credentials cannot satisfy MFA. Session keys include model and ID. `CredentialSet` supports scoped lookup and typed opaque IDs, including UUIDs; multi-association routes use `<model>-<id>`, while an unknown type prefix falls back to bare-ID lookup across configured associations.

Account MFA is a persisted preference. Add an account-level non-null boolean named `two_factor_enabled` with default `false` to each mapped account table. Existing hosts must backfill it from any credential with a previously enabled `two_factor_enabled_at`, including records that are now unverified, before enabling the feature. Enrolling a credential does not enable MFA. `account.enable_two_factor!` requires a usable verified, enabled, unlocked credential; `disable_two_factor!` opts out. While MFA is on, direct credential disable and destroy operations lock the account row and prevent removal of the final usable factor. Override `two_factor_last_factor_removal_action` to return `:disable` when removal should clear the account preference in the same transaction. Custom columns use `two_factor_enabled_attribute` or `write_two_factor_enabled!`.

The owning account supplies the persisted preference and credential association:

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :two_factorable
  has_many :two_factor_credentials
end
```

Mappings with non-empty MFA association sets for one account class must agree; scopes without factor associations do not add a conflict. Inconsistent mappings raise `Vouch::ConfigurationError`. Configure matching associations explicitly with `associations: {two_factorable: [...]}` when needed. Per-account settings override global defaults:

```ruby
authenticates_with :two_factorable,
  two_factorable: {max_attempts: 3, lockout_duration: 10.minutes}
```

If multiple owner associations qualify, override `two_factor_account_class` and/or `two_factor_account` explicitly. Vouch raises ambiguity rather than choosing by reflection order.

TOTP/WebAuthn hosts override challenge and verification methods while preserving eligibility, lockout, version binding, and replay prevention. Magic-link hosts call `issue_sign_in_code!` and `verify_sign_in_code`. After verification, record `{"type", "id"}` in `signed_in_via_session_key` and call `complete_sign_in(account, method: :magic_link)`. Hosts may instead pass the verified credential directly with `signed_in_via: credential`; Vouch uses this only to exclude the primary credential from a later second-factor picker, while the host remains responsible for verifying the proof first. Hosts own issuance rate limits and recovery UI. Implement each credential delivery method (`deliver_verification_code`, `deliver_sign_in_code`, or `deliver_two_factor_code`); the default raises `Vouch::ConfigurationError` so an unconfigured flow cannot report success.

OtpCourier receives Rails key material through Vouch's integration. If it is initialized outside the standard integration, configure its secret explicitly.
