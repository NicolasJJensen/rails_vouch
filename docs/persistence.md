# Handling cancelled authentication changes

This guide is for custom authentication services and credential adapters. The supplied controllers already handle unsuccessful authentication writes.

A Rails callback can prevent a reset token, password, or verification state from being saved. Your code must not treat that operation as successful or deliver a token whose state was rolled back.

## Generate, then deliver

For a custom password-reset service:

```ruby
result = user.generate_password_reset_token!
user.deliver_password_reset_token(result.value) if result.ok?
```

If a callback cancels token persistence, generation raises `Vouch::Persistence::Cancelled` instead of returning a usable token. Handle it at your endpoint boundary:

```ruby
rescue Vouch::Persistence::Cancelled
  render :new, status: :unprocessable_entity
```

Delivery errors also propagate. Handle those separately if your application needs a delivery retry.

## Result conventions

| Operation | Success | Invalid proof | Cancelled write |
| --- | --- | --- | --- |
| `generate_password_reset_token!` | Result carrying the raw token | Not applicable | Raises `Vouch::Persistence::Cancelled` |
| `reset_password_with_token!` | `Result.ok` | Unsuccessful result | `Result.cancelled` |
| `start_verification!` | Result carrying a challenge token | Not applicable | Raises `Vouch::Persistence::Cancelled` |
| `complete_verification!` | `Result.ok` | `Result.invalid` | `Result.cancelled` |
| `challenge!` | Result carrying an MFA token | Not applicable | Raises `Vouch::Persistence::Cancelled` |
| `verify_challenge` | `Result.ok` | `Result.invalid` | `Result.cancelled` |
| `issue_sign_in_code!` | Result carrying a sign-in token | Not applicable | Raises `Vouch::Persistence::Cancelled` |
| `verify_sign_in_code` | `Result.ok` | `Result.invalid` | `Result.cancelled` |

Methods with lockout protection can return `Result.locked`. A cancelled proof-consumption write leaves the proof available for retry after the cancellation condition is removed. Unexpected database errors retain their normal exception types.

## Group custom database changes

Use the persistence wrapper when several changes must succeed together and a cancelled write needs a distinct error:

```ruby
Vouch::Persistence.transaction(user) do
  user.lock!
  Vouch::Persistence.update!(user, last_login_at: Time.current)
  AuditLog.create!(user: user, event: "sign_in")
end
```

This example assumes your `last_login_at` column and `AuditLog` model. `transaction(record)` opens a new transaction; a cancelled operation raises `Vouch::Persistence::Cancelled` and reloads a persisted record. That exception inherits from `ActiveRecord::RecordNotSaved`.

`save!(record)`, `update!(record, attributes)`, and `create!(model_or_relation, attributes)` check that the write succeeded. Validation and uniqueness failures remain ordinary Active Record errors.

## External effects and callbacks

A database rollback cannot undo an email or SMS that was already sent. For authentication controller customizations, put database work in the `commit_of_*` callbacks and post-completion work in the outer `after_*` callback. The [lifecycle timing table](sessions-and-hooks.md#lifecycle-hooks) explains when each runs, including registrations that still require MFA.

Custom credential implementations can run the [adapter shared examples](credential-adapter-contract.md) to check cancellation, expiry, lockout, and single-use behavior.
