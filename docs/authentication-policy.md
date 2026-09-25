# Authentication policy

Use an authentication policy to decide whether someone may sign in and whether they must complete MFA. Vouch applies the policy to password and OAuth sign-in, as well as custom flows that call `complete_sign_in`.

## Block suspended users

```ruby
# lib/application_authentication_policy.rb
class ApplicationAuthenticationPolicy < Vouch::AuthenticationPolicy
  def allowed?(account, method:, provider:, controller:)
    super && !account.suspended?
  end
end
```

```ruby
# config/initializers/vouch.rb
require_relative "../../lib/application_authentication_policy"

Vouch.configure do |config|
  config.authentication_policy = ApplicationAuthenticationPolicy
end
```

The argument is called `account` because it is the credentials record: your `User` in a single-model setup, or `Account` in the multi-tenant example. `suspended?` is a predicate you implement on that model. Calling `super` retains Vouch's default lockout check.

| Argument | Value |
| --- | --- |
| `account` | Credentials record attempting authentication. |
| `method` | Authentication method, such as `:password`, `:oauth`, or `:registration`. |
| `provider` | OAuth provider name, or `nil`. |
| `controller` | Controller completing authentication. |

`config.authentication_policy` accepts a class, its name as a string, or an instance implementing the policy methods. A class is instantiated for the request. Use a string when Rails autoloads your policy and needs to resolve the current class after a reload:

```ruby
config.authentication_policy = "ApplicationAuthenticationPolicy"
```

The explicit `require_relative` example loads the class at boot.

## MFA and trusted providers

By default, an account that has enabled MFA must complete its local second factor, including after OAuth. If your company provider already enforces the required second factor, you can exempt that provider from the additional local challenge:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.oauth_mfa_providers = ["company_sso"]
end
```

The value must match the provider name returned by OmniAuth. Use this only for providers whose MFA you trust.

For a more specific rule, override `two_factor_required?` on your policy:

```ruby
# In ApplicationAuthenticationPolicy
 def two_factor_required?(account, method:, provider:, controller:)
   super || account.requires_mfa_by_policy?
 end
```

`requires_mfa_by_policy?` is an example predicate, not a required Vouch method. Replace that expression with your application's rule. When making MFA mandatory, use the [generated enrollment pages](verification-and-mfa.md#enroll-a-phone) to establish a usable factor before enforcing the requirement.

## Pending sign-in timeout

A person may pause between entering a password and submitting their MFA code or selecting an organisation. Limit how long that first authentication proof remains usable:

```ruby
Vouch.configure do |config|
  config.pending_authentication_ttl = 10.minutes
end
```

When it expires, they must authenticate again. This does not set an inactivity timeout for a completed login.

## Lock an account after failed passwords

Generate the tracking columns on the credentials model:

```sh
bin/rails generate vouch:lockable User
bin/rails db:migrate
```

The migration adds:

```ruby
change_table :users do |t|
  t.bigint :consecutive_locks, default: 0, null: false
  t.integer :failed_attempts, default: 0, null: false
  t.datetime :locked_at
end
add_index :users, :locked_at
```

Enable the feature on `User`:

```ruby
# app/models/user.rb
authenticates_with :lockable
```

Configure the threshold and initial lockout duration:

```ruby
Vouch.configure do |config|
  config.lockable.max_failed_attempts = 5
  config.lockable.lockout_duration = 5.minutes
end
```

Repeated lockouts increase the duration. A successful login clears the failure count and lockout history. For a multi-tenant application, run `bin/rails generate vouch:lockable Account` and enable the feature on `Account`; the same columns are added to `accounts`. All memberships use that account's password and lockout state.

## Revoke established sessions

Changing a password invalidates established sessions and pending sign-in attempts. Lockout blocks new sign-in by default; to invalidate existing logins on lockout too:

```ruby
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

The scope generator includes `auth_session_version`. When a security action should end earlier sessions, call `invalidate_authentication_sessions!` on the credentials record:

```ruby
# In your account-security action, after authorizing the change
current_user.invalidate_authentication_sessions!
```

For an existing model that lacks the column, add it with:

```sh
bin/rails generate migration AddAuthSessionVersionToUsers auth_session_version:bigint
```

Set the generated column's default and null constraint:

```ruby
# In a migration
add_column :users, :auth_session_version, :bigint, null: false, default: 0
```

The invalidation method increments the version under a record lock. Vouch includes the version in its session fingerprint. Sessions with the old value are rejected when next restored. Impersonation restoration also checks the original operator's fingerprint.

## Restrict available memberships

For a linked multi-tenant scope, you may want suspended memberships hidden from the organisation selector even though the account can still sign in elsewhere:

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::MembershipSessionsController
  private

  def candidate_identities_for(account)
    super.where(active: true)
  end
end
```

This example assumes an `active` column on your membership model. `super` keeps the account ownership restriction. Vouch checks eligibility again when the person submits their choice, so a membership disabled while the form was open cannot be selected.

## Custom authentication flows

If you write an endpoint that calls `complete_sign_in`, handle its result:

| Result | Next step |
| --- | --- |
| `:signed_in` | Redirect after completed authentication. |
| `:needs_two_factor` | Show the MFA challenge list. |
| `:needs_selection` | Show the membership selector. |
| `:no_identity` | Deny membership access; no eligible identity remains. |
| `:denied` | Show authentication failure. |

The supplied controllers already handle these outcomes. A Warden strategy you add yourself must use a name other than Vouch's `:password` strategy.

## MFA required by an organisation

An account may permit several factor types while an organisation requires a particular authenticator. Define membership requirements on the same authentication policy:

```ruby
# In ApplicationAuthenticationPolicy
 def membership_mfa_requirements(account, identity:, tenant:, controller:)
   return unless tenant.requires_authenticator?

   {
     credential_types: [Totp],
     max_age: 15.minutes,
     allow_recovery_codes: false
   }
 end
```

`requires_authenticator?` is an example of an organisation setting you supply. `identity` is the selected membership; `account` owns its credentials. Return `nil` when the organisation adds no MFA requirement.

Vouch evaluates these rules after choosing the membership. A recent qualifying factor can satisfy the requirement without another challenge. Otherwise the person must complete an allowed factor before entering that organisation. The account can remain signed in while organisation access is pending.

A recovery code is recorded as recovery-code authentication, even when attached to a `Totp`. Set `allow_recovery_codes: true` only when those codes satisfy the organisation's requirement. Account-level provider exemptions do not automatically make a provider an approved organisation authenticator.

Vouch checks membership requirements again when restoring access. Disabling the factor, expiring the evidence or changing the organisation's requirements can require another challenge.
