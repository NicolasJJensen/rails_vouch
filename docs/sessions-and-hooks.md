# Sessions and lifecycle hooks

Authentication session behavior is part of the integration contract. This guide extends the [README](../README.md); see [authentication policy](authentication-policy.md) and [persistence](persistence.md) for related boundaries.

## Account and membership sessions

An account scope owns credential authentication and required MFA. Linked membership scopes select identities under that account. Membership rotation preserves its parent account and sibling membership sessions. Account sign-out clears all dependent memberships; membership sign-out normally clears only that membership. Ending a membership during impersonation clears the parent as well, so no untracked target account remains authenticated.

A direct account login uses its account redirect. A membership guard records the requested scope and protected URL, then resumes that scope after account authentication. The selected membership must still belong to the current account on every restored request.

## Session rotation and preservation

Authentication rotates the session. CSRF, flash, locale, return destination, credential drafts, and a pending invitation survive by default. Intermediate context is scoped to its flow.

```ruby
Vouch.configure do |config|
  config.preserved_session_keys = ["cart"]
  config.preserved_auth_scopes = [:admin]
end
```

Preserved scopes are re-established through Warden serialization. Arbitrary session keys and scopes are not copied automatically. Credential drafts retain the existing `credential_drafts` getter/setter contract and default to `{}`. Direct ActiveRecord drafts require a host serializer; JSON cookies do not provide one automatically. Encode drafts explicitly or use a suitable server-side store, respect its size limits, and never deserialize client-supplied class names without an allowlist.

## Lifecycle and event hooks

Lifecycle hooks support `before_*`, `after_*`, and `around_*` for sign-in, sign-out, sign-up, OAuth sign-in/link/account creation, and impersonation start/end. Event hooks use `on_*` for password reset token generation, password change, invitation token generation/acceptance, and MFA verification.

```ruby
class Accounts::PasswordsController < Vouch::PasswordsController
  on_password_reset_token_generation do |account, token|
    AccountMailer.password_reset(account, token).deliver_later
  end
end
```

Sign-in, registration, and OAuth account creation run `before_*`, `around_*`, core work, and `on_*` hooks inside their database transaction. A halted hook or an `ActiveRecord::Rollback` raised inside that authentication operation does not establish a session. Do not wrap an auth-controller action in an outer transaction that can roll back after the action yields: Rails session and Warden mutation are not database-transactional, so they cannot be rolled back with application records. Registration rollback removes its account and membership changes.

Lifecycle `after_*` callbacks run only after a successful lifecycle operation and after every open joinable Active Record transaction has committed. They therefore do not run when an enclosing host transaction rolls back. Sign-in, sign-up, and OAuth account-creation callbacks run after the resulting session state has been published; sign-up and OAuth account creation describe successful account creation even if a later identity selection cannot complete. Sign-out and impersonation callbacks run after Warden and session state change. An after-callback exception cannot undo a committed operation. Use the supplied identity argument inside sign-in hooks; `current_identity` is bound only after authentication succeeds. Warden `after_authentication` fires once with the final identity, after required factors and selection. Password verification alone does not fire Warden user callbacks.

Successful second factor remains part of the completion hook context through identity selection. OAuth continuation stores a protected-session payload containing provider, UID, and the default profile fields email, name, and image. It never retains provider access or refresh tokens. The selected provider fields have no imposed length bound, so cookie-session hosts that need stricter size limits should override protected `serialize_oauth` and `parse_oauth` together with a bounded, serializable representation. The original callback AuthHash is available during immediate callback completion and `oauth_account_creation`; after MFA or identity selection, `oauth_sign_in` hooks and profile updates receive the reconstructed payload. Delivery exceptions propagate to host controllers, which should translate expected delivery failures into the desired response.
