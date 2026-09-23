# Sessions and lifecycle hooks

Sign-in keeps your application’s session data. Lifecycle hooks let you add work
before authentication changes, inside their database transaction, or after
successful completion.

## Session rotation

Vouch renews the Rails session identifier during authentication. Renewal keeps
ordinary application data, such as a shopping cart or locale, while Vouch
removes authentication state belonging to the affected scope. CSRF, flash,
return destinations, credential drafts, pending invitations, and MFA state
are retained or cleared according to the current flow.

For example, `session[:cart]` keeps its contents after sign-in. Unrelated
Warden logins also remain signed in. Warden renews the session identifier when
it stores a user; Vouch also requests renewal for intermediate authentication
steps such as MFA, before a user is stored. Renewal prevents reuse of the old
session identifier without discarding application data.

Credential drafts use the controller's `credential_drafts` getter and setter.
If a draft contains an Active Record object, provide your own serializer or use
a server-side store; do not deserialize client-supplied class names without an
allowlist.

## Lifecycle hooks

Lifecycle hooks are class methods on Vouch controllers. They are available for
sign-in, sign-out, sign-up, OAuth sign-in, OAuth linking, OAuth account
creation, invitation revocation, and impersonation start and end.

Each lifecycle has an outer chain and a commit chain. For example, sign-in
uses `before_sign_in`, `around_sign_in`, and `after_sign_in`, plus
`before_commit_of_sign_in`, `around_commit_of_sign_in`, and
`after_commit_of_sign_in`.

```ruby
class Users::SessionsController < Vouch::SessionsController
  before_sign_in do |account, identity|
    Rails.logger.info("signing in #{identity.id} for account #{account.id}")
  end

  before_commit_of_sign_in do |account, identity|
    AuditLog.create!(account: account, event: "sign_in", identity: identity)
  end

  after_commit_of_sign_in do |_account, identity|
    identity.update!(last_seen_at: Time.current)
  end

  after_sign_in do |_account, identity|
    Analytics.track("signed_in", identity_id: identity.id)
  end
end
```

The normal order is:

| Phase | Transaction state | Runs when |
| --- | --- | --- |
| `before_*` | No Vouch persistence transaction | Before the lifecycle starts |
| `around_*` | Outside the commit transaction | Around the complete lifecycle |
| `before_commit_of_*` | Inside a new Active Record transaction | Before lifecycle writes |
| `around_commit_of_*` | Inside that transaction | Around lifecycle writes |
| `after_commit_of_*` | Inside that transaction | After writes, before the transaction finishes |
| `after_*` | After the transaction commits | After successful persistence; completed sign-in also publishes session state |

| Lifecycle | Arguments | Example use |
| --- | --- | --- |
| `sign_in` | Credentials record, identity; verified factor is added after successful MFA completion | Audit a login. |
| `sign_out` | Current identity | Audit a logout. |
| `sign_up` | Credentials record; created identity is added after creation | Create associated registration data. |
| `oauth_sign_in` | Credentials record, identity, `auth_hash:` | Record a provider login. |
| `oauth_link` | Current identity, `auth_hash:` | Record a newly linked provider. |
| `oauth_account_creation` | `auth_hash:` initially; account and identity are added after creation | Provision an OAuth signup. |
| `invitation_revocation` | Invitation identity, credentials account | Audit an invitation withdrawal. |
| `impersonation_start` | Current identity, target | Record who began impersonation. |
| `impersonation_end` | Current identity, original operator | Record restoration. |

Each row has the outer and `commit_of_*` callback chains shown above. In a
single-model setup, the credentials record and identity are the same `User`.
`AuditLog` and `Analytics` in the example are services you supply.

Event hooks use `on_*` for password reset token generation, password changes,
invitation token generation and acceptance, and two-factor verification:

```ruby
class Users::PasswordResetsController < Vouch::PasswordResetsController
  on_password_reset_token_generation do |account, token|
    AccountMailer.password_reset(account, token).deliver_later
  end
end
```

| Event hook | Arguments |
| --- | --- |
| `on_password_reset_token_generation` | Credentials record, raw reset token |
| `on_password_change` | Credentials record |
| `on_invitation_token_generation` | Submitted identifier, invitation identity |
| `on_invitation_acceptance` | Invitation identity, credentials record |
| `on_two_factor_verification` | Credentials record, selected identity, verified credential |

Use ActiveHooks' `with_env` option when your callback needs the callback
environment rather than the arguments directly.

## Cancellation and transaction boundaries

Throwing `:abort` from a `before_*` callback cancels the lifecycle before any
transaction begins. An `around_*` callback that does not call its continuation
also cancels the lifecycle. Cancellation in the commit chain rolls back the
transaction. An `ActiveRecord::Rollback` raised by persistence or an
`after_commit_of_*` callback has the same rollback effect.

For example, reject a login before writing its audit entry:

```ruby
# In Users::SessionsController
before_commit_of_sign_in do |user, _identity|
  throw(:abort) if user.suspended?
end
```

This assumes your model supplies `suspended?`. Returning `false` from a
callback does not cancel it; use `throw(:abort)`.

Vouch rejects an authentication lifecycle started inside an existing joinable
Active Record transaction with `Vouch::ConfigurationError`. This keeps the
outer `after_*` callbacks from running before an enclosing transaction can later roll
back. Start the authentication request outside the enclosing transaction and use
the commit chain for database work.

`after_sign_in` and `after_oauth_sign_in` observe the completed login.
`after_sign_up` and `after_oauth_account_creation` observe successful record
creation, which can still be followed by MFA before the person is signed in.
Sign-out callbacks observe no current identity for the signed-out scope. An
exception from `after_*` cannot undo the committed database operation.

## Account and membership sessions

An account scope authenticates the account and completes required MFA. A
membership scope selects one identity owned by that account. Vouch checks the
account again when restoring a membership session, so a stale or unrelated
membership cannot become current.

Signing out of an account clears its dependent membership sessions. Signing
out of a membership clears that membership and its impersonation state. During
impersonation, ending the membership session also clears the parent account
session when required to avoid leaving an untracked target session.


## Authentication events

Second-factor completion keeps the verified credential through identity
selection and passes it to `on_two_factor_verification`. OAuth continuation
state stores the provider, UID, and the default profile fields `email`, `name`,
and `image`; it does not store provider access or refresh tokens. Hosts using a
cookie session with stricter size limits can override the protected
`serialize_oauth` and `parse_oauth` methods together with a bounded,
serializable format.
