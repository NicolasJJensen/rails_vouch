# Results and cancelled authentication writes

The generated controllers handle expected authentication failures and display useful errors. Read this guide when writing a custom credential adapter or calling a model operation directly. Ordinary application records still use normal Rails persistence.

## Contents

- [Choose a result or an exception](#choose-a-result-or-an-exception)
- [Why Vouch checks required writes](#why-vouch-checks-required-writes)
- [Transaction boundaries](#transaction-boundaries)
- [Delivery and other external effects](#delivery-and-other-external-effects)

## Choose a result or an exception

Password-reset operations offer normal and bang methods. For example, `reset_password_with_token` returns an unsuccessful result for an invalid or expired token; `reset_password_with_token!` raises `Vouch::OperationFailed` with that same result. Both return a successful `Vouch::Result` when the password changes.

A custom service can let its caller handle the result:

```ruby
# app/services/password_replacement.rb
class PasswordReplacement
  def self.call(user, token:, password:, password_confirmation:)
    user.reset_password_with_token(
      token,
      password: password,
      password_confirmation: password_confirmation
    )
  end
end
```

| Result | Meaning |
| --- | --- |
| `ok?` | The operation succeeded; `value` holds its return value. |
| `invalid?` | The proof or submitted attributes were rejected. |
| `locked?` | Attempt protection prevents another attempt now. |
| `cancelled?` | A required write or lifecycle callback cancelled the operation. |
| `already_verified?` | Verification is already saved for this subject; no new proof was accepted. |
| `pending?` | A controller flow needs another step, such as MFA; sign-in is not complete. |

For a bang operation, rescue `Vouch::OperationFailed` at the boundary where you handle that expected failure. Its `result` retains the status and metadata. Where available, `result.metadata[:record].errors` contains field errors and `result.error` is the underlying expected exception. Unexpected exceptions, including an unavailable database, retain their original types.

> An exclamation mark does not make a failed proof successful. Choose the method that fits your control flow, and check the result or handle its exception. Individual feature guides list their supported operations.

For controller customization, use [the action result block](controllers.md#customize-action-responses) instead of rebuilding a supplied endpoint.

## Why Vouch checks required writes

Rails deliberately catches `ActiveRecord::Rollback` at a transaction boundary. A model callback that raises it can make a bang write return `nil`, rather than raise to its caller. Ordinary validation failures and `throw :abort` normally produce Active Record exceptions from bang writes; this safeguard addresses the narrower swallowed-rollback case.

Authentication cannot continue if consuming its proof was cancelled: the code would otherwise remain usable. Vouch therefore checks required writes and transaction completion before reporting success.

| Mechanism | Responsibility |
| --- | --- |
| Record lock | Prevent competing changes while checking and consuming a proof. |
| Rails transaction | Commit or roll back related database writes together. |
| Checked write | Detect a required write cancelled by a callback. |
| Transaction completion check | Detect cancellation before the transaction completes. |

`Vouch::Persistence` is the small internal module implementing those checks on top of Active Record. It is not a model or a replacement persistence framework for your application. Its internal `Cancelled` exception inherits from `ActiveRecord::RecordNotSaved`; public operation methods translate expected failures into their result/exception contract.

## Transaction boundaries

Vouch opens authentication lifecycle transactions on the mapped credentials model's writing connection. Associated records and callback writes that must be atomic must use that same connection. Separate connection pools are separate transaction boundaries, even if they point to the same database.

A custom adapter using Vouch's internal checked transaction gets a savepoint when already inside a transaction. Releasing that savepoint does not commit the enclosing transaction. It must not publish authentication or send a message on the assumption that the outer transaction has committed.

Vouch rejects authentication lifecycles started inside an existing joinable transaction on the mapped writing connection. Add related database work through the [transactional lifecycle callbacks](sessions-and-hooks.md#lifecycle-hooks) instead.

## Delivery and other external effects

A rollback cannot undo an email, SMS or external API call. The supplied controllers publish successful events after their required database work succeeds. Customize their existing delivery method rather than registering a second delivery callback.

For your own lifecycle work, use transactional callbacks for database writes and `after_commit_of_*` for external effects. An exception after commit cannot undo already committed changes; handle delivery retries separately from database rollback.

Custom two-factor adapters can run the [credential adapter contract](credential-adapter-contract.md) to test cancellation, expiry, lockout and single use.
