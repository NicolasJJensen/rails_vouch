# Authentication policy

The default policy blocks locked accounts and requires MFA when the account has enabled it. You do not need a custom policy for ordinary sign-in.

Add one when the same rule must apply across authentication methods. For example, suspending a user should block both password and OAuth sign-in; a check in the password controller alone would leave OAuth unaffected. Vouch also applies the policy to [custom authentication endpoints](advanced-custom-authentication.md) that use its completion API.

To end logins that already exist when an account is suspended, also [invalidate its sessions](#revoke-established-sessions).

## Contents

- [Block suspended users](#block-suspended-users)
- [MFA during sign-in](#mfa-during-sign-in)
- [Pending sign-in timeout](#pending-sign-in-timeout)
- [Revoke established sessions](#revoke-established-sessions)
- [MFA evidence and application permissions](#mfa-evidence-and-application-permissions)

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
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.authentication_policy = "ApplicationAuthenticationPolicy"
end
```

The explicit `require_relative` example loads the class at boot.

## MFA during sign-in

An account that enables MFA completes its local second factor after password or OAuth authentication. A provider name does not establish that MFA occurred.

Override `two_factor_required?` only when your application needs a different sign-in rule:

```ruby
# lib/application_authentication_policy.rb
class ApplicationAuthenticationPolicy < Vouch::AuthenticationPolicy
  def two_factor_required?(account, method:, provider:, controller:)
    super || account.requires_mfa_by_policy?
  end
end
```

`requires_mfa_by_policy?` is an example application predicate. The [MFA management pages](mfa.md#enroll-a-phone) let people enroll usable factors before your application makes them mandatory.

## Pending sign-in timeout

A person may pause between entering a password and submitting their MFA code or selecting an organisation. The default limit is ten minutes. Set a different limit in the existing initializer:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.pending_authentication_ttl = 10.minutes
end
```

Pending authentication is stored in the Rails session, including when it began and which account supplied the first proof. It is not a completed Warden login. If account MFA is required, Vouch does not publish the account to Warden until MFA succeeds.

In a multi-tenant flow, the account may already be signed in while membership selection remains pending. That does not grant access to the pending membership.

When the pending step expires, the person must authenticate again. This setting also limits how long each verified OAuth provider remains usable during registration; it does not set an inactivity timeout for established logins.

## Revoke established sessions

Changing a password invalidates established sessions and pending sign-in attempts. [Lockout](lockout.md) blocks new sign-in by default; to invalidate existing logins on lockout too:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

To end earlier sessions after a security change, call `invalidate_authentication_sessions!` on the signed-in user:

```ruby
# app/controllers/security_controller.rb
class SecurityController < AuthenticatedController
  def destroy_sessions
    # Authorize this security change with your application's permissions.
    current_user.invalidate_authentication_sessions!
    redirect_to new_user_session_path, notice: "Sign in again to continue."
  end
end
```

In a multi-tenant application, call the method on `Account`, which owns authentication.

Vouch tracks revocation with an `auth_session_version` column, included by the scope generator. For an existing model that lacks it, add the column with:

```sh
bin/rails generate migration AddAuthSessionVersionToUsers auth_session_version:bigint
```

Set the generated column's default and null constraint:

```ruby
# db/migrate/<timestamp>_add_auth_session_version_to_users.rb
class AddAuthSessionVersionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :auth_session_version, :bigint, null: false, default: 0
  end
end
```

The invalidation method increments the version under a record lock. Vouch includes the version in its session fingerprint. Sessions with the old value are rejected when next restored. Impersonation restoration also checks the original operator's fingerprint.

## MFA evidence and application permissions

For selecting which memberships are available, use [membership filtering](model-mapping.md#exclude-inactive-memberships). Organisation-specific MFA requirements belong to your application's permissions checks. For example, your application can require recent company-email MFA before allowing access to a workspace.

`authentication_evidence(scope:)` is available on application controllers and views. It returns an array of current MFA proofs for the authenticated account behind that scope. Different credentials have separate entries; completing another challenge with the same credential refreshes that entry. Vouch excludes proof whose account, credential, verified subject or enabled period no longer matches.

| Field | Meaning |
| --- | --- |
| `method` | `two_factor` or `recovery_code`. |
| `verified_at` | ISO 8601 time when the MFA proof completed. |
| `credential_type`, `credential_id`, `credential_method` | The authenticator actually used for ordinary MFA. |
| `owner_type`, `owner_id` | The owner of a recovery-code set, when recovery was used. |

For example, an application can require a recent TOTP proof before displaying a page:

```ruby
# app/controllers/projects_controller.rb
class ProjectsController < ApplicationController
  before_action :authenticate_user!

  def show
    proofs = authentication_evidence(scope: :user)
    recent_totp = proofs.any? do |proof|
      proof["method"] == "two_factor" && proof["credential_method"] == "totp" &&
        Time.iso8601(proof["verified_at"]) >= 15.minutes.ago
    end
    # Apply your application's authorization here, including recent_totp.
    head :forbidden unless recent_totp
  end
end
```

In a multi-tenant setup, `authentication_evidence(scope: :account)` reads the account's proofs; supplying a linked membership scope reads the same account-owned collection. Signed-out scopes return an empty array.

Your permissions code decides which methods, credential records and ages are acceptable. Recovery proof does not claim use of the lost credential. Passwords, OAuth sign-in and contact verification are not entries in this collection.

> Evidence is current session state, not an audit history. Use lifecycle callbacks if your application needs a permanent log.
