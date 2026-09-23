# Review fixes

> Historical engineering record. For the current API and setup, start with the [README](../README.md).

The scope is the 25 findings from the September review and its design recommendations.
Issue 15 reserves `:password` by agreement. It does not require a strategy rename.
Issue 5 uses subject/version-bound challenges. OAuth callbacks use separate scope paths.

| Findings | Target behavior | Status |
| --- | --- | --- |
| 1, 13 | Scoped, locked revocation; invited membership completion; existing-account login | Implemented; request regressions |
| 2, 3, 4, 25 | One completion policy enforces factors, candidates, expiry, and hook context | Implemented; request and policy regressions |
| 5 | Subject changes invalidate verification and all earlier challenge versions | Implemented; credential and concurrency regressions |
| 6, 7, 8, 9, 21 | Atomic token consumption, secure randomness, model configuration | Implemented; credential and concurrency regressions |
| 10, 11, 20 | Generated hosts boot; schemas and opaque primary keys match runtime | Implemented; generator and host integration regressions |
| 12, 14, 17 | Scope-aware controller adapter and persistent impersonation restoration | Implemented; request, Warden, and eager-loading regressions |
| 15 | Password strategy is explicitly reserved | Retained as agreed; documented |
| 16, 18, 19, 22, 23, 24 | Host-safe loading, routes, associations, dependencies, and keys | Implemented; mapping, routing, resolver, and request regressions |
| Design | Explicit policy, session preservation, reflection overrides, compatibility coverage | Implemented; local validation passed; CI matrix added |

## Initial regression run

The first new regression batch ran before implementation: 23 examples, 21 failures.
The two passing examples guard valid draft persistence and a negative OAuth path.
Additional policy, generator, compatibility, and concurrency tests are added within each workstream.

## Regression coverage

- `spec/requests/users/review_regressions_spec.rb`: missing/unauthorized invitation revocation, existing and placeholder invitation acceptance, disabled factors, candidate restrictions, password/lock/expiry invalidation, exact reset-token delivery and consumption, impersonation restoration and authorization, OAuth lock/MFA policy, hook aborts, registration rollback, and factor context through selection.
- `spec/lib/vouch/controller_policy_spec.rb`: scoped identity access, declared session keys/scopes, provider assurance overrides, custom account associations, password rotation between verification and completion, and completion blocks.
- `spec/lib/vouch/review_regressions_spec.rb` and individual credential concern specs: subject/version binding, verification invalidation, stale objects, drafts, cryptographic recovery randomness, per-model settings, and distinct password-reset APIs.
- `spec/lib/vouch/concurrency_regressions_spec.rb`: separate PostgreSQL connections for single-use password reset, confirmation nonce, backup code, recovery lockout, and subject-version writes.
- Mapping, route builder, configuration, login resolver, and CredentialSet specs: explicit/gated reflection, ambiguity, custom associations, UUIDs, callback paths/methods, Warden configuration, serializer failures, and current classes after reload.
- `spec/lib/generators/` and `spec/integration/`: emitted APIs/schema, controller ejection, generated-host migration/login/session persistence, and eager loading.

## Integration changes

Verifiable hosts need `verification_version` (bigint, default 0, non-null). Invitable identity models need `invitation_registration_required` (boolean, default false, non-null). Generators and dummy migrations include these fields. Callback-bypassing writes to credential subjects must perform equivalent verification invalidation.

At the time of this review, auth controllers shared a base class and configurable inherited callbacks. That design has since been replaced by direct `ApplicationController` inheritance and the `Vouch::Authentication` concern; use an application-defined protected base for page guards. A host that already installs Warden can disable gem middleware installation and call `Vouch.configure_warden` on its manager.

Default OAuth callback paths include the scope. Host OmniAuth middleware and provider redirect URLs must match. Local locks and MFA apply to OAuth by default; explicit provider assurance exemptions are configurable.

Impersonation requires host authorization. Switching targets retains the original operator; both stop endpoints restore that operator, without a nested stack. Restoration rejects a locked operator or a changed password fingerprint.

## Completed local validation

- Full suite: **513 examples, 0 failures**, including real generated-host login/session persistence, eager loading, and deterministic PostgreSQL concurrency checks.
- Final impersonation restoration hardening, applied after the full run began: **46 examples, 0 failures** across impersonation requests, review regressions, and route/serializer specs.
- Final credential/request integration batch: **154 examples, 0 failures**. This includes the dummy TOTP adapter's locked verification and timestep replay protection.

The final tree contains one additional restoration example covered by the passing 46-example batch.

Generated-host test remnants were removed after validation. The test database migration versions match dummy migrations 1–14, with no generated public tables or temporary generated schemas remaining.

## Validation limits

Local validation uses Ruby 3.3.6, Rails 8.1.3, PostgreSQL, and sibling dependency checkouts. The compatibility workflow exercises released dependencies and additional versions when CI runs; adding the workflow is not evidence that those jobs have passed. No live OAuth provider, Devise host, alternate database adapter, or browser presentation is certified by this suite.

Core account/membership and tenant/membership reflections do not support polymorphic associations, even with explicit overrides. Polymorphic OAuth ownership is supported separately; see [model mapping](model-mapping.md).
