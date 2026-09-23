# Authentication policy

Use an authentication policy to decide whether someone may sign in and whether they must complete MFA. Vouch applies the policy to password and OAuth sign-in, as well as custom flows that call `complete_sign_in`.

## Block suspended users

```ruby
# app/models/application_authentication_policy.rb
class ApplicationAuthenticationPolicy < Vouch::AuthenticationPolicy
  def allowed?(account, method:, provider:, controller:)
    super && !account.suspended?
  end
end
```

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.authentication_policy = "ApplicationAuthenticationPolicy"
end
```

The argument is called `account` because it is the credentials record: your `User` in a single-model setup, or `Account` in the multi-tenant example. `suspended?` is a predicate you implement on that model. Calling `super` retains Vouch's default lockout check.

| Argument | Value |
| --- | --- |
| `account` | Credentials record attempting authentication. |
| `method` | Authentication method, such as `:password`, `:oauth`, or `:registration`. |
| `provider` | OAuth provider name, or `nil`. |
| `controller` | Controller completing authentication. |

The configured value may also be an object responding to `allowed?` and `two_factor_required?` with these keyword arguments.

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

Implement `requires_mfa_by_policy?` and the corresponding factor-enrollment process in your application. Requiring MFA without a usable factor leaves the user unable to complete sign-in.

## Pending sign-in timeout

A person may pause between entering a password and submitting their MFA code or selecting an organisation. Limit how long that first authentication proof remains usable:

```ruby
Vouch.configure do |config|
  config.pending_authentication_ttl = 10.minutes
end
```

When it expires, they must authenticate again. This does not set an inactivity timeout for a completed login.

## Revoke established sessions

Changing a password invalidates established sessions and pending sign-in attempts. Lockout blocks new sign-in by default; to invalidate existing logins on lockout too:

```ruby
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

For other security changes, add an `auth_session_version` column to your credentials model and increment it to invalidate earlier sessions:

```ruby
# In a migration
add_column :users, :auth_session_version, :integer, null: false, default: 0
```

```ruby
# In your account-security action or service
user.with_lock do
  user.increment!(:auth_session_version)
end
```

Vouch includes that value in its session fingerprint when the attribute exists. Sessions with the old value are rejected when next restored. Impersonation restoration also checks the original operator's fingerprint.

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
