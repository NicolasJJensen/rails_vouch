# Agreed authentication fixes

> Historical engineering record. For the current API and setup, start with the [README](../README.md).

The implementation covers the 14 findings and the accepted design improvements. Session storage remains the host's responsibility. The compatibility suite does not test Devise coexistence.

## Regression scoreboard

| Finding | Fix | Regression coverage |
| --- | --- | --- |
| 1. Rails 7 transaction exits | Avoid nonlocal returns after transaction writes | Standalone backup consumption/replay and recovery counter/lockout assertions |
| 2. OTP replay | Separate credential-row nonces for verification, sign-in, and second factor | Replay, restored cookie, reissuance, flow isolation, stale instances, and concurrent consumption |
| 3. Mutable signed-link subject | Bind tokens to a configured subject and rotate the nonce on subject changes | Recipient changes from A to B and back to A |
| 4. Authentication after rollback | Complete transactional hooks before publishing the session | Sign-in rollback preserves counters and denies the next authenticated request |
| 5. Premature Warden events | Suppress callbacks, clear the temporary password-proof cache, and emit final authentication with the identity | No event before MFA, exactly one event after completion, no authenticated identity inside transactional hooks |
| 6. Reset token survives password change | Clear reset state on persisted password changes | Direct password update invalidates an outstanding reset link |
| 7. Renamed primary keys | Resolve records through each model's primary key | Warden restoration with a renamed key, existing UUID coverage |
| 8. Polymorphic tenant reflection | Reject polymorphic tenant relationships; explicit names resolve ambiguity only between concrete relationships | Polymorphic tenant discovery and custom association traversal |
| 9. Custom account model names | Generate matching relationship declarations and route overrides | Generated Owner/Member host migrates, boots, authenticates, and restores its cookie, including bounded index names on Rails 7 |
| 10. Namespaced generation | Parse the final role separator and align tables, classes, and foreign keys | Namespaced generated host migration and real authentication |
| 11. Migration-blocking schema checks | Validate schema on feature use | Unmigrated class inclusion, missing-column errors on use, generated feature installation before migration |
| 12. Lockout backoff | Count actual lock events | Successive expired locks double duration, with cap coverage |
| 13. Current password reuse | Compare the candidate against the persisted current digest | Direct update rejects the current password, with archive-history coverage |
| 14. Aborted credential removal | Check destruction outcome and display failure | Host before-destroy callback leaves the credential present without a success notice |

## Design contracts

- Account MFA is a persisted preference on the mapped authentication account. A verified and enabled credential may remain enrolled while the account preference is off. Enabling the account requires at least one usable credential; explicit account disable clears only the account preference. Credential disable and removal lock the account and reject removal of the last usable factor while account MFA is on. Hosts can override `two_factor_last_factor_removal_action(credential)` to return `:disable`, which clears the account flag in the same transaction.
- New installations should add a non-null `two_factor_enabled` boolean to the account table (default `false`) and backfill existing accounts from the host's current MFA policy before enabling the feature. The gem does not silently infer or turn MFA off during rollout. Hosts with a different column can set `self.two_factor_enabled_attribute` or override `write_two_factor_enabled!`.

- Route relationship overrides use one flat `associations:` hash. Unambiguous relationships need no overrides.
- Password-history association selection belongs to the account model. It works without routes and stays consistent across scopes.
- Pending authentication, established sessions, and impersonation restoration share a fingerprint. A persisted host `auth_session_version` revokes all three.
- Sign-in, registration, and OAuth account creation run lifecycle hooks inside their database transaction. Registration and OAuth-creation rollback also remove account and membership writes.
- Candidate membership filtering uses a Set.
- Generator route insertion respects nested feature blocks. Complex route syntax receives a manual insertion snippet.
- Host paths, helpers, selected routes, controller overrides, and existing Warden configuration remain configurable.

## Validation

The first regression batch ran before implementation: 18 examples, 17 failures. Subsequent fixture corrections supplied matching password confirmations and consistent reflection target classes. The separate Rails 7.0 backup test also failed before the fix because consumption did not persist.

Completed checks:

- Rails 8.1.3 full suite: **542 examples, 0 failures**.
- Rails 8.1.3 final concurrency and generator additions: **15 examples, 0 failures**.
- Rails 8.1.3 final request/controller suite: **150 examples, 0 failures**.
- Rails 8.1.3 final lifecycle suite: **10 examples, 0 failures**.
- Rails 7.0.10 generated hosts after the index-length fix: **3 examples, 0 failures**.
- Rails 7.0.10 final full suite: **547 examples, 0 failures**.
- Rails 7.0.10 additional OAuth rollback regression: **1 example, 0 failures**.
- Rails 7.0.10 focused request/model regressions: **22 examples, 0 failures**.
- Rails 7.0.10 and Rails 8.1.3 standalone transactions: backup replay and recovery lockout assertions passed.
- Final generator parser checks: **12 examples, 0 failures**.
- All **174 Ruby source files** parse successfully.
- Compatibility workflow YAML parses successfully.

All final checks passed. The initial Rails 7.0 full run exposed an oversized generated index name. The generator now bounds those names, and the complete rerun passed. Local runs use Ruby 3.3.6 and sibling dependency checkouts. CI is configured for Ruby 3.1/Rails 7.0, Ruby 3.2/Rails 7.2, and Ruby 3.3/Rails 8.0 and 8.1 with released dependencies. That CI matrix has not run during this local task.

The Rails 7 results above are historical compatibility validation. The current gemspec requires Rails >= 8, < 9.

## Host upgrade notes

Existing hosts must add the enabled feature nonce columns and `consecutive_locks`. Fresh generators include these columns. The README provides a migration example and the model association configuration.

Outstanding OTP challenges without nonces become invalid. Existing sessions using the previous fingerprint format expire on their next request.

Persisted proofs have database replay protection. Unsaved credential drafts retain in-memory state and require host session protection. Hosts that wrap authentication in an additional outer transaction must coordinate response/session publication with that outer transaction. Lifecycle after hooks are transactional, not after-commit delivery hooks.

Core account/membership and tenant/membership reflections do not support polymorphic associations, even with explicit overrides. Polymorphic OAuth ownership is supported separately; see [model mapping](model-mapping.md).
