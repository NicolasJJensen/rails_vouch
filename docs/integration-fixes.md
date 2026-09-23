# Authentication integration fixes

> Historical engineering record. For the current API and setup, start with the [README](../README.md).

This records the implementation following the 7 September 2026 review. New regressions reproduced the gem defects before their fixes.

## Fixes and regression coverage

| Finding | Change | Regression coverage |
| --- | --- | --- |
| Callbacks silently cancel proof persistence | Check bang-write results and roll back the complete operation. Return failure before authentication publication. | `spec/lib/vouch/persistence_regressions_spec.rb` covers before/after callbacks, OTP, magic links, second factors, signed verification, password resets, backup codes, and recovery codes. |
| Cancelled account, membership, OAuth, or invitation writes report success | Apply checked persistence to registration, OAuth creation/linking, invitation operations, and login bookkeeping. | `spec/requests/users/cancelled_persistence_regressions_spec.rb`, `spec/requests/users/timezone_and_persistence_regressions_spec.rb`, and Invitable concern specs. |
| Request time zones change authentication fingerprints | Serialize account and second-factor timestamps in UTC. | Established-session and second-factor-to-selection requests in `timezone_and_persistence_regressions_spec.rb`. |
| Namespaced forms submit an unexpected parameter key | Use Rails `model_name.param_key`. | `spec/requests/namespaced_account_form_regression_spec.rb` checks registration and password forms. |
| Namespaced feature generators produce invalid paths, migrations, and associations | Share model metadata across generators, including concrete controller ejection. Generate explicit backup table and parent class names. | `spec/lib/generators/namespaced_model_generator_spec.rb` and `namespaced_generator_integration_spec.rb`. The integration test migrates generated models and consumes real verification and sign-in proofs. |
| OAuth ownership assumes membership association names | Resolve OAuth ownership independently, including account subclasses, with an explicit `oauth_account` override for ambiguity. | `spec/lib/vouch/oauth_ownership_regression_spec.rb`. |

Cancellation checks preserve the distinction between `ActiveRecord::Rollback`, explicit callback abort exceptions, and unexpected database errors. Proof consumers return failure for cancellation. Issuance and state changes raise `Vouch::Persistence::Cancelled`, which inherits `ActiveRecord::RecordNotSaved`.

## Integration improvements

- Optional [credential adapter contracts](credential-adapter-contract.md) cover OTP and the dummy host TOTP implementation. Hosts supply provider-specific issuance, clock control, and persistence failure simulation.
- `spec/lib/vouch/warden_host_interoperability_spec.rb` checks independent serialized Warden scopes across sign-in and subsequent restoration. It also checks host authentication callbacks on public and protected actions.
- Shared generator metadata respects loaded model table names, customized model names, and namespace paths without triggering application autoloading.

## Host responsibilities

Password-history concurrency remains the host's responsibility. The README explains locking before assigning password changes. The gem does not add an automatic locking policy to arbitrary host writes.

Warden scope ownership remains documentation-only. Hosts reserve each mapping's primary, account, and impersonation scopes and coordinate other authentication gems.

Hosts can revoke pending magic-link authentication through the persisted account `auth_session_version`. The README explains the policy and its effect on established sessions.

Release compatibility work remains deferred.

## Validation

The pre-change suite passed 548 examples. The new regression files first reproduced the relevant failures. Focused reruns passed after the fixes. The first full rerun exposed additional subclass, generator, and lifecycle response regressions. Those fixes passed focused reruns. All nine concurrency tests passed, including simultaneous consumers on separate PostgreSQL connections.

Full-suite result: **626 examples, 0 failures**, in 4 minutes 20.4 seconds. All 186 Ruby files passed syntax checks.

This run used Ruby 3.3.6, Rails 8.1.3, local PostgreSQL, and the existing development dependency configuration. The suite grew by 78 examples.

Run the complete suite with:

```sh
bundle exec rspec
```

Core account/membership and tenant/membership reflections do not support polymorphic associations, even with explicit overrides. Polymorphic OAuth ownership is supported separately; see [model mapping](model-mapping.md).
