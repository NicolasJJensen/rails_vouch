# Lockout

## Contents

- [Add lockout tracking](#add-lockout-tracking)
- [Configure lockout](#configure-lockout)
- [Invalidate active sessions](#invalidate-active-sessions)

## Add lockout tracking

```sh
bin/rails generate vouch:lockable User
bin/rails db:migrate
```

```ruby
change_table :users do |t|
  t.bigint :consecutive_locks, default: 0, null: false
  t.integer :failed_attempts, default: 0, null: false
  t.datetime :locked_at
  t.index :locked_at
end
```

The generator adds `authenticates_with :lockable` to the selected credentials model. In a shared-account setup, run it for `Account`: memberships then share that password and its lockout state.

## Configure lockout

```ruby
Vouch.configure do |config|
  config.lockable.max_failed_attempts = 5
  config.lockable.lockout_duration = 5.minutes
end
```

Repeated lockouts extend the duration. A successful password sign-in clears failed attempts and lockout history. Authentication policy can add host rules such as suspension; see [authentication policy](authentication-policy.md).

Set a policy for one model instead of every mapping by passing options to its declaration:

```ruby
authenticates_with :lockable,
  lockable: { max_failed_attempts: 8, lockout_duration: 15.minutes }
```

## Invalidate active sessions

Lockout blocks a new authentication by default. To also reject already-established sessions after lockout:

```ruby
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

For a security action that ends existing sessions, authorize it first and call `invalidate_authentication_sessions!` on the credentials record. The `auth_session_version` increments under a record lock; stale sessions are rejected when Warden restores them. It also invalidates pending authentication state. See [session invalidation](authentication-policy.md#revoke-established-sessions).
