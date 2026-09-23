# Controllers and routes

Vouch generates application controllers that subclass its endpoint controllers:

```ruby
class Accounts::SessionsController < Vouch::SessionsController
  auth_scope :account
end

class Users::SessionsController < Vouch::MembershipSessionsController
  auth_scope :user
end
```

The gem's endpoint controllers inherit your `ApplicationController` and include the `Vouch::Authentication` concern. This concern provides authentication-flow guards, lifecycle hooks, and access to the endpoint's mapping.

Ordinary application controllers receive the smaller `Vouch::ApplicationHelpers` concern automatically. They do not need to include the endpoint concern.

## Protect application pages

Keep `ApplicationController` free of authentication requirements. Use application-specific base controllers:

```ruby
class AuthenticatedController < ApplicationController
  before_action :authenticate_account!
end

class TenantController < AuthenticatedController
  before_action :authenticate_user!
end

class BillingController < AuthenticatedController
end

class ProjectsController < TenantController
end
```

For single-model `User` authentication, use `authenticate_user!` directly on the protected base. A guard saves the requested GET URL, then redirects to its scope's sign-in endpoint.

## Endpoint responsibilities

| Gem controller | Responsibility |
| --- | --- |
| `Vouch::SessionsController` | Account or single-model credential sign-in and sign-out |
| `Vouch::MembershipSessionsController` | Select an eligible membership under an authenticated account; end that membership session |
| `Vouch::RegistrationsController` | Create the credentials record and run application registration provisioning |
| `Vouch::PasswordsController` | Request reset delivery, validate reset links, and change passwords |
| `Vouch::TwoFactorChallengeController` | Complete MFA during account authentication |
| `Vouch::TwoFactorCredentialsController` | Enroll and remove credentials for an authenticated account; application-specific enrollment remains required |
| `Vouch::OmniAuthsController` | Process provider callbacks, sign in, register, or link a provider identity |
| `Vouch::InvitationsController` | Create, accept, and revoke invitations |
| `Vouch::ImpersonationsController` | Start authorized impersonation and restore the original actor |

## Redirects

Shared methods belong in `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  protected

  def after_sign_in_path_for(record, scope:)
    scope == :admin ? admin_root_path : projects_path
  end

  def after_sign_up_path_for(record, scope:)
    onboarding_path
  end

  def after_sign_out_path_for(scope:)
    welcome_path
  end
end
```

Replace the example destinations with routes from your application. Defaults are `root_path` for sign-in and registration, and the relevant scope's sign-in route for sign-out.

An endpoint-specific override takes precedence over the shared method:

```ruby
class Accounts::SessionsController < Vouch::SessionsController
  auth_scope :account

  private

  def after_sign_in_path
    billing_path
  end
end
```

This override applies when this controller finishes authentication. Completion in an MFA or membership controller uses that finishing controller's override or the shared method. Use shared methods for behavior that must apply across every completion path.

A saved protected-page destination takes precedence over the sign-in fallback. Registration uses its registration destination, including after MFA and membership selection. Password reset returns to the account sign-in page; it does not automatically authenticate the account.

## Explicit controller scopes

Vouch can infer the mapping from a controller namespace: `Users::SessionsController` matches `:user`. Generated controllers declare the scope explicitly.

Set `auth_scope` yourself when using a namespace that does not identify the mapping:

```ruby
class Portal::SessionsController < Vouch::SessionsController
  auth_scope :account
end
```

```ruby
auth.scope :account, model: "Account" do
  auth.sessions controller: "portal/sessions"
end
```

With several configured scopes, `Portal` does not tell Vouch which one this controller serves. Without an explicit declaration, inference fails instead of guessing.

## Route reference

The following account tables assume `auth.scope :account, model: "Account"`. Optional routes exist only when their declaration is included. Helpers also have Rails `_url` variants for absolute URLs.

| Declaration | Verb and URL | Helper | Action |
| --- | --- | --- | --- |
| `auth.sessions` | `GET /accounts/sign_in` | `new_account_session_path` | sessions `new` |
| | `POST /accounts/sign_in` | `account_session_path` | sessions `create` |
| | `DELETE /accounts/sign_out` | `account_sign_out_path` | sessions `destroy` |
| `auth.registrations` | `GET /accounts/sign_up` | `new_account_registration_path` | registrations `new` |
| | `POST /accounts/sign_up` | `account_registration_path` | registrations `create` |
| `auth.passwords` | `GET /accounts/password/new` | `new_account_password_path` | passwords `new` |
| | `POST /accounts/password` | `account_password_path` | passwords `create` |
| | `GET /accounts/password/edit?token=…` | `edit_account_password_path(token: token)` | passwords `edit` |
| | `PATCH/PUT /accounts/password` | `account_password_path` | passwords `update` |
| `auth.two_factor` | `GET /accounts/two_factor_challenges` | `account_two_factor_challenges_path` | challenge `index` |
| | `GET /accounts/two_factor_challenges/:id` | `account_two_factor_challenge_path(id)` | challenge `show` |
| | `POST /accounts/two_factor_challenges/:id/send_code` | `send_code_account_two_factor_challenge_path(id)` | challenge `send_code` |
| | `PATCH/PUT /accounts/two_factor_challenges/:id` | `account_two_factor_challenge_path(id)` | challenge `update` |
| `auth.two_factor` | `GET /accounts/two_factor_credentials` | `account_two_factor_credentials_path` | credentials `index` |
| | `GET /accounts/two_factor_credentials/new` | `new_account_two_factor_credential_path` | credentials `new` |
| | `POST /accounts/two_factor_credentials` | `account_two_factor_credentials_path` | credentials `create` |
| | `DELETE /accounts/two_factor_credentials/:id` | `account_two_factor_credential_path(id)` | credentials `destroy` |
| `auth.oauth_callbacks` | `GET /accounts/auth/:provider/callback` | No named helper | OmniAuth `callback` |
| | `GET /accounts/auth/failure` | `accounts_auth_failure_path` | OmniAuth `failure` |

OAuth request-phase URLs are supplied by OmniAuth; see [OAuth setup](oauth.md). Callback methods and paths can be configured for the provider.

These membership routes assume `auth.scope :user, account_scope: :account, identity: "User", tenant: "Organisation"`:

| Declaration | Verb and URL | Helper | Action |
| --- | --- | --- | --- |
| `auth.sessions` | `GET /users/sign_in` | `new_user_session_path` | membership sessions `new` |
| | `POST /users/sign_in` | `user_session_path` | membership sessions `create` |
| | `DELETE /users/sign_out` | `user_sign_out_path` | membership sessions `destroy` |
| `auth.invitations` | `GET /users/invitation/new` | `new_user_invitation_path` | invitations `new` |
| | `POST /users/invitation` | `user_invitation_path` | invitations `create` |
| | `DELETE /users/invitation` | `user_invitation_path` | invitations `destroy` |
| | `GET /users/invitation/accept?token=…` | `accept_user_invitation_path(token: token)` | invitations `accept` |
| `auth.impersonation` | `POST /users/impersonations/:id` | `user_impersonate_path(id)` | impersonations `create` |
| | `DELETE /users/impersonations` | `user_stop_impersonation_path` | impersonations `destroy` |
| | `DELETE /users/impersonations/all` | `user_stop_all_impersonations_path` | impersonations `destroy_all` |

Single-model `:user` scopes use the account endpoint behavior with `/users` and `user` helper prefixes. `path:` changes URL prefixes; `as:` changes route-helper prefixes. Neither changes the authentication scope or current-record helper names.

Use Rails to inspect the routes your application actually enabled:

```sh
bin/rails routes
```

## Copying an endpoint into your application

Usually a subclass override or hook is enough. To copy an entire endpoint for larger changes:

```sh
bin/rails generate vouch:eject users membership_sessions --auth-scope user
```

The copied controller still uses Vouch's authentication concern and runtime mapping. Review the generated filename and point `auth.sessions controller:` at it when it differs from the default `users/sessions` path.
