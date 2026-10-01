# Sessions and lifecycle hooks

Sign-in keeps your application’s session data. Lifecycle hooks let you add work
before authentication changes, inside their database transaction, or after
successful completion.

## Contents

- [Session rotation](#session-rotation)
- [Lifecycle hooks](#lifecycle-hooks)
- [Share sign-in callbacks](#share-sign-in-callbacks)
- [Event hooks](#event-hooks)
- [Cancellation and transaction boundaries](#cancellation-and-transaction-boundaries)
- [Account and membership sessions](#account-and-membership-sessions)
- [Authentication evidence](#authentication-evidence)

## Session rotation

Vouch renews the session identifier during authentication to prevent session fixation. Application data such as `session[:cart]` and `session[:locale]` is preserved, as are unrelated authentication scopes.

## Lifecycle hooks

Lifecycle hooks are class methods on Vouch controllers. They are available for
sign-in, sign-out, sign-up, OAuth linking, OAuth account
creation, invitation acceptance and revocation, and impersonation start and end.

Use `before_sign_in` or `after_sign_in` for database work that must roll back if sign-in fails. Use `after_commit_of_sign_in` for work outside the database, such as notifying another service after sign-in succeeds.

Vouch opens this transaction on the mapped credentials model's writing connection, including when that model uses a separate authentication database. Associated records and callback writes must use that same writing connection to commit or roll back together. A Rails transaction cannot make writes across separate connections atomic.

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::SessionsController
  before_sign_in do |account, identity|
    AuditLog.create!(account: account, event: "sign_in", identity: identity)
  end

  after_commit_of_sign_in do |_account, identity|
    Analytics.track("signed_in", identity_id: identity.id)
  end
end
```

> `AuditLog` and `Analytics` are example application classes. In a single-model setup, both callback arguments refer to the same `User`.

The table describes transaction boundaries. Around callbacks wrap their continuation; their nesting follows callback registration order. `before_commit_of_sign_in` runs before Vouch opens the transaction; `before_sign_in` runs inside it.

| Phase | Transaction state | Runs when |
| --- | --- | --- |
| `before_commit_of_*` | Before Vouch opens its transaction | Decide whether to start the operation |
| `around_commit_of_*` | Wraps the transaction and session publication | Observe the complete operation |
| `before_*` | Inside the transaction | Add database work before the operation |
| `around_*` | Inside the transaction | Wrap the operation's database work |
| `after_*` | Inside the transaction | Add database work after the operation |
| `after_commit_of_*` | After commit and successful session publication | Deliver notifications or call external services |

The following table lists the available lifecycles, their arguments, and a
typical use. Each supports the phases in the preceding table.

| Lifecycle | Arguments | Example use |
| --- | --- | --- |
| `sign_in` | Credentials record, identity, `authentication_method:`; OAuth also supplies `auth_hash:` and a verified MFA factor is added after completion | Audit password, OAuth or custom sign-in. |
| `sign_out` | Current identity | Audit a logout. |
| `sign_up` | Credentials record; created identity is added after creation | Create associated registration data. |
| `oauth_link` | Current identity, `auth_hash:` | Record a newly linked provider. |
| `oauth_account_creation` | `auth_hash:` initially; account and identity are added after creation | Provision an OAuth signup. |
| `invitation_acceptance` | Invitation identity, credentials account | Create records for the accepted membership. |
| `invitation_revocation` | Invitation identity, credentials account | Audit an invitation withdrawal. |
| `impersonation_start` | Original operator, target | Record who began impersonation. |
| `impersonation_end` | Current identity, original operator | Record restoration. |

## Share sign-in callbacks

Password and OAuth use the same `sign_in` lifecycle. To cover both, including completion in an MFA or membership-selection controller, declare the callback in their shared application parent:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Vouch::ControllerHelpers

  after_commit_of_sign_in :record_sign_in

  private

  def record_sign_in(account, identity, *factors, authentication_method:, **options)
    Analytics.track(
      "signed_in",
      account_id: account.id,
      identity_id: identity.id,
      method: authentication_method,
      provider: options[:auth_hash]&.provider
    )
  end
end
```

> `Analytics` is your application's service. The trailing positional and keyword arguments allow this method to receive additional factor and provider context.

The method describes the first-factor flow, such as `:password`, `:oauth` or `:registration`; choosing a membership under an already authenticated account uses `:session`. It survives intermediate MFA and selection requests. It is separate from MFA proof.

A callback declared only in `Users::SessionsController` belongs to that controller: it does not run when a sibling MFA controller completes the sign-in. Put common callbacks in the parent, and controller-specific behavior in the corresponding subclass. Ordinary block callbacks may ignore arguments they do not need; named methods should accept the keywords they use and `**` for the remainder.

## Event hooks

Event hooks use `on_*` for password reset token generation, password changes, invitation token generation, and two-factor verification.

Password reset already has a delivery callback: Vouch calls the model’s `deliver_password_reset_token` method, which the generator supplies. Change that method to customize delivery:

```ruby
class Account < ApplicationRecord
  def deliver_password_reset_token(token)
    AccountPasswordResetMailer.reset(self, token).deliver_later
  end
end
```

The generated application password-reset controller registers
`on_password_reset_token_generation` and calls
`account.deliver_password_reset_token(token)`. The generated model method
then calls its generated mailer. To use a different mailer or delivery
service, override the model method as shown above. Do not add a second
password-reset token-generation hook for delivery: it would run alongside the
generated hook and can send the reset message twice.

Use an event hook for additional event-specific work that is not the supplied
delivery path:

```ruby
class Users::PasswordResetsController < Vouch::PasswordResetsController
  on_password_change do |account|
    AuditLog.create!(account:, event: "password_changed")
  end
end
```

| Event hook | Arguments |
| --- | --- |
| `on_password_reset_token_generation` | Credentials record, raw reset token |
| `on_password_change` | Credentials record |
| `on_invitation_token_generation` | Submitted identifier, invitation identity |
| `on_two_factor_verification` | Credentials record, selected identity, verified credential |

`on_invitation_acceptance` is a convenient spelling of `after_invitation_acceptance`; both run inside the acceptance transaction.

For advanced callback arguments and wrapping, see the [ActiveHooks documentation](https://github.com/NicolasJJensen/active_hooks).

## Cancellation and transaction boundaries

Throwing `:abort` from a `before_commit_of_*` callback cancels the lifecycle before a transaction begins. An `around_*` callback that does not call its continuation
also cancels the lifecycle. Cancellation in a transactional callback rolls back the transaction. Raising `ActiveRecord::Rollback` from that transactional work has the same effect.

For example, reject a login before writing its audit entry:

```ruby
# In Users::SessionsController
before_sign_in do |user, _identity|
  throw(:abort) if user.suspended?
end
```

This assumes your model supplies `suspended?`. Returning `false` from a
callback does not cancel it; use `throw(:abort)`.

Vouch rejects an authentication lifecycle started inside an existing joinable
transaction on that credentials model's writing connection with `Vouch::ConfigurationError`. This keeps the
outer `after_commit_of_*` callbacks from running before an enclosing transaction can later roll
back. Start the authentication request outside the enclosing transaction and use the ordinary lifecycle callbacks for database work.

`after_commit_of_sign_in` observes the completed login for both password and OAuth.
`after_commit_of_sign_up` and `after_commit_of_oauth_account_creation` observe successful record
creation, which can still be followed by MFA before the person is signed in.
Sign-out callbacks observe no current identity for the signed-out scope. An exception from `after_commit_of_*` cannot undo the committed database operation.

## Account and membership sessions

An account scope authenticates the account and completes required MFA. A
membership scope selects one identity owned by that account. Vouch checks the
account again when restoring a membership session, so a stale or unrelated
membership cannot become current.

Signing out of an account clears its dependent membership sessions. Signing
out of a membership clears that membership and its impersonation state. During
impersonation, signing out clears the participating sessions and the restoration
stack. To return to the operator's session instead, use the
[stop impersonation action](impersonation.md#start-and-stop).

Membership impersonation preserves the operator's account authentication while
making only the authorized target membership current. The target's account is
not signed in. Ordinary membership selection is blocked until impersonation ends.


## Authentication evidence

MFA completion records the method used and when it was verified. Recovery codes are recorded as `recovery_code`, not as the credential's ordinary method. [Organisation MFA policies](authentication-policy.md#mfa-required-by-an-organisation) use that evidence when deciding whether another challenge is required.

OAuth field retention is described in [retained provider data](oauth.md#retain-additional-provider-data).
