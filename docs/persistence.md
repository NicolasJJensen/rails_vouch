# Persistence and callbacks

Proof persistence is part of the authentication contract. This guide extends the [README](../README.md); see [sessions and hooks](sessions-and-hooks.md) and [verification and MFA](verification-and-mfa.md).

## Consumption and issuance

Authentication proof consumption commits state changes before reporting success. Built-in verification, reset, backup-code, and recovery operations detect callbacks that raise `ActiveRecord::Rollback`, roll back, and return failure. Signed verification returns `nil`; other proof consumers return `false`.

Issuance and state-change methods raise `Vouch::Persistence::Cancelled`, a subclass of `ActiveRecord::RecordNotSaved`, when a callback silently cancels persistence. They never return usable proofs or publish authentication success. Unexpected database errors and explicit callback abort exceptions retain normal exception behavior.

These operations use transactions and savepoints. External effects in callbacks cannot be undone by rollback, so arrange delivery and other side effects after successful persistence. Host callbacks still control validation and persistence.

## Adapter contract

Host-defined MFA credentials can use the optional [RSpec adapter contract](credential-adapter-contract.md). It checks issuance, invalid proofs, replay, expiry, stale instances, disabled credentials, and persistence failures. RSpec remains a host test dependency.
