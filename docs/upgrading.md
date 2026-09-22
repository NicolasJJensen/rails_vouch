# Upgrading existing schemas

The current release is **0.1.0**, the initial release. The notes here are pre-release and manual-schema migration guidance for applications that already adopted development versions or generated partial schemas; they do not describe a released version-to-version transition. Start with the [README](../README.md), then use the feature guides for the relevant contract.

## Authentication proof columns

Fresh feature generators include current columns. Existing installations need an application migration before enabling updated concerns. Adapt table names and add only columns for features actually enabled:

```ruby
class AddAuthenticationProofState < ActiveRecord::Migration[8.0]
  def change
    add_column :phones, :verification_nonce, :string
    add_column :phones, :sign_in_nonce, :string
    add_column :phones, :two_factor_nonce, :string
    add_column :accounts, :consecutive_locks, :bigint, default: 0, null: false
  end
end
```

Also add account `registration_required` for invitations as described in [invitations](invitations.md), and add `two_factor_enabled` before enabling account MFA. Existing accounts with a previously enabled credential require a backfill, including now-unverified records.

## Rollout effects

Each lock event increments `consecutive_locks`. Expiry permits another attempt; later failures lock again with doubled duration up to the existing cap. Successful authentication clears attempt and lock counters. Existing rows start at zero recorded lock events.

Outstanding OTP challenges without nonces become invalid. The unified session fingerprint invalidates older sessions on their next request, so plan rollout and sign-in messaging accordingly. Run `bin/rails vouch:verify` after migrations and model wiring; it reports mapping and feature contract failures without altering schema.

## Compatibility boundaries

Ruby >= 3.2 and Rails >= 8, < 9 are required, with per-version Ruby minimums. PostgreSQL is the tested database. Ordinary scalar primary keys, including UUIDs and renamed keys, are supported; composite keys are outside the contract. Cookie and server-side session storage remain host choices.
