# Lockout

Lockout temporarily blocks authentication after repeated incorrect passwords. Add it to the existing model that owns password authentication.

## Contents

- [Add lockout tracking](#add-lockout-tracking)
- [Configure lockout](#configure-lockout)
- [Expiry and repeated lockouts](#expiry-and-repeated-lockouts)
- [Existing sessions](#existing-sessions)

## Add lockout tracking

```sh
bin/rails generate vouch:lockable User
bin/rails db:migrate
```

The generator:

- Adds the lockout columns and index to `users` through a migration.
- Adds `Vouch::Authenticatable` and `authenticates_with :lockable` to the existing `User` model when missing.
- Creates no controller, view, route or mailer.

The migration adds these fields (generated migrations also check for existing columns):

```ruby
# db/migrate/<timestamp>_add_lockable_to_users.rb
class AddLockableToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users do |t|
      t.bigint :consecutive_locks, default: 0, null: false
      t.integer :failed_attempts, default: 0, null: false
      t.datetime :locked_at, index: true
    end
  end
end
```

If authentication lives on a separate credentials model, such as `Account`, generate against that model instead:

```sh
bin/rails generate vouch:lockable Account
bin/rails db:migrate
```

## Configure lockout

Defaults are five failed attempts, a 30-minute first lockout, and a fresh allowance of attempts after expiry. To change them globally:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.lockable.max_failed_attempts = 8
  config.lockable.lockout_duration = 5.minutes
  config.lockable.reset_attempts_after_lockout = true
end
```

Or set options for one model:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password

  authenticates_with :lockable,
    lockable: {
      max_failed_attempts: 8,
      lockout_duration: 15.minutes,
      reset_attempts_after_lockout: false
    }
end
```

## Expiry and repeated lockouts

With `reset_attempts_after_lockout: true`, the first failed attempt after expiry starts a fresh allowance. With `false`, the previous failure count remains: one more incorrect attempt can immediately lock the account again.

Repeated lockouts double the duration until a sign-in completes. With the default base duration:

| Lockout | Duration |
| --- | --- |
| First | 30 minutes |
| Second | 1 hour |
| Third | 2 hours |
| Ninth and later | 128 hours |

The multiplier is capped at 256 times the configured base duration. Expiry restores the attempt allowance by default, but does not clear this escalation history. A completed sign-in clears the failed-attempt count, lock timestamp and escalation history. Passing the password step alone while MFA remains pending does not clear them.

`lock_account` manually locks the account and returns a `Vouch::Result`; `lock_account!` returns the same successful result or raises `Vouch::OperationFailed`. A cancelled write does not report a successful lock.

`locked?` and `lockout_time_remaining` report the current state. Ordinary password requests during an active lock do not extend it. `strategy: :none` disables automatic threshold locking; it does not disable failure counting or explicit `lock_account!` calls.

## Existing sessions

Lockout blocks new authentication by default. To also reject session restoration while the account is locked:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

> This global setting rejects restoration while the lock is active. It does not permanently revoke a session merely because a lockout occurred.

For a security action that must revoke previous sessions, authorize the action and call `invalidate_authentication_sessions!` on the credentials record. That operation requires the `auth_session_version` column supplied by the scope generator. See [session invalidation](authentication-policy.md#revoke-established-sessions).
