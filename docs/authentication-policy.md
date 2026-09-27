# Authentication policy

The default policy blocks locked accounts and requires MFA when the account has enabled it. You do not need a custom policy for ordinary sign-in.

Add one when the same rule must apply across authentication methods. For example, suspending a user should block both password and OAuth sign-in; a check in the password controller alone would leave OAuth unaffected. Vouch also applies the policy to [custom authentication endpoints](advanced-custom-authentication.md) that use its completion API.

This policy decides admission and MFA requirements. Permissions such as who may edit a project belong in your application's authorization code. To end logins that already exist, use [session invalidation](#revoke-established-sessions).

## Contents

- [Block suspended users](#block-suspended-users)
- [MFA and trusted providers](#mfa-and-trusted-providers)
- [Pending sign-in timeout](#pending-sign-in-timeout)
- [Revoke established sessions](#revoke-established-sessions)
- [Restrict available memberships](#restrict-available-memberships)
- [MFA required by an organisation](#mfa-required-by-an-organisation)

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

`requires_mfa_by_policy?` is an example predicate, not a required Vouch method. Replace that expression with your application's rule. When making MFA mandatory, use the [generated enrollment pages](mfa.md#add-phone-based-mfa) to establish a usable factor before enforcing the requirement.

## Pending sign-in timeout

A person may pause between entering a password and submitting their MFA code or selecting an organisation. Limit how long that first authentication proof remains usable:

```ruby
Vouch.configure do |config|
  config.pending_authentication_ttl = 10.minutes
end
```

Pending authentication is stored in the Rails session, including when it began and which account supplied the first proof. It is not a completed Warden login. If account MFA is required, Vouch does not publish the account to Warden until MFA succeeds.

In a multi-tenant flow, the account may already be signed in while membership selection or an additional organisation challenge remains pending. That does not grant access to the pending membership.

When the pending step expires, the person must authenticate again. This setting also bounds OAuth registration continuations; it does not set an inactivity timeout for established logins.

## Revoke established sessions

Changing a password invalidates established sessions and pending sign-in attempts. [Lockout](lockout.md) blocks new sign-in by default; to invalidate existing logins on lockout too:

```ruby
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

To end earlier sessions after a security change, call `invalidate_authentication_sessions!` on the signed-in user:

```ruby
# In your account-security action, after authorizing the change
current_user.invalidate_authentication_sessions!
```

In a multi-tenant application, call the method on `Account`, which owns authentication.

Vouch tracks revocation with an `auth_session_version` column, included by the scope generator. For an existing model that lacks it, add the column with:

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

The requirements can restrict the credential class, its authentication method, or both:

All keys are optional. Return `nil` or an empty hash for no additional requirement. A nonempty requirements hash requires qualifying MFA evidence; omitted restrictions use these defaults:

| Option | Meaning | When omitted |
| --- | --- | --- |
| `credential_types` | Allowed model classes, such as `[Totp]` or `[Phone, Totp]` | Any configured credential class |
| `credential_methods` | Allowed method names, useful when one model implements several authenticator types | Any credential method |
| `max_age` | Maximum age of the successful proof before another challenge is required | No additional age limit |
| `allow_recovery_codes` | Whether a recovery code may replace that challenge | `false` |

A credential's method name defaults to its model name. Set a stable name on the model:

```ruby
# In Phone
two_factor_auth_name :sms
```

For a model that implements multiple methods, return the method of that record. For example, if your model stores the type in `authenticator_kind`:

```ruby
def authentication_method
  authenticator_kind.to_sym
end
```

A policy can then require `credential_methods: [:totp]` even when SMS and TOTP records share a model class.

Vouch evaluates these rules after choosing the membership. A recent qualifying factor can satisfy the requirement without another challenge. Otherwise the person must complete an allowed factor before entering that organisation. The account can remain signed in while organisation access is pending. If no enrolled factor matches, the generated page links to account-level factor management so the person can enroll an allowed factor before returning.

A recovery code is recorded as recovery-code authentication, even when attached to a `Totp`. Set `allow_recovery_codes: true` only when those codes satisfy the organisation's requirement. Account-level provider exemptions do not automatically make a provider an approved organisation authenticator.

Vouch checks membership requirements again when restoring access. Disabling the factor, expiring the evidence or changing the organisation's requirements can require another challenge.
