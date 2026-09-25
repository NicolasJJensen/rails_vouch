# Controllers and routes

## Protect pages

Put the authentication requirement on a base controller for pages that require sign-in:

```ruby
# app/controllers/authenticated_controller.rb
class AuthenticatedController < ApplicationController
  before_action :authenticate_user!
end

# app/controllers/projects_controller.rb
class ProjectsController < AuthenticatedController
end
```

Keep `ApplicationController` accessible without signing in, because Vouch's sign-in and registration controllers inherit from it too.

Vouch automatically includes `Vouch::ApplicationHelpers` in application controllers. This supplies `authenticate_user!`, `current_user`, and `user_signed_in?` for the `:user` scope, and exposes the current-record helpers to views. In a multi-tenant setup where `User` belongs to `Account`, `authenticate_user!` checks both the account login and the selected user membership. You do not need a second account filter.

## Customize an authentication endpoint

The scope generator creates subclasses you can edit:

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::SessionsController
  private

  def after_sign_in_path
    projects_path
  end
end
```

Vouch's endpoint controllers inherit your `ApplicationController` and include the `Vouch::Authentication` concern. That concern provides the endpoint's scope, authentication flow, and lifecycle hooks. Ordinary page controllers only need the automatically installed application helpers.

### Redirects

Override `after_sign_in_path`, `after_sign_up_path`, or `after_sign_out_path` in the controller that completes the operation. For example:

```ruby
# app/controllers/users/registrations_controller.rb
class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def after_sign_up_path
    onboarding_path
  end
end
```

To use the same destination when an operation finishes in another controller, such as an MFA challenge, define the shared methods:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  protected

  def after_sign_in_path_for(record, scope:)
    projects_path
  end

  def after_sign_up_path_for(record, scope:)
    onboarding_path
  end

  def after_sign_out_path_for(scope:)
    root_path
  end
end
```

A controller-specific override takes precedence over its shared method. The `record` is the authenticated record for `scope`; the scope argument lets applications with separate logins choose different destinations.

By default, sign-in and registration go to `root_path`, and sign-out goes to the scope's sign-in page. When a guard redirects someone from a protected GET page, successful sign-in returns them to that page instead of the fallback. Registration keeps its sign-up destination through MFA and membership selection. Password reset returns to sign-in without logging the user in.

### Controller names and scopes

`Users::SessionsController` infers the `:user` scope from `Users`. Use `auth_scope` when the namespace has another name:

```ruby
# app/controllers/portal/sessions_controller.rb
class Portal::SessionsController < Vouch::SessionsController
  auth_scope :user
end
```

```ruby
# config/routes.rb, inside Vouch.routes
 auth.scope model: "User" do
   auth.sessions controller: "portal/sessions"
 end
```

Here, `Portal` does not identify the `:user` scope, so the declaration makes that connection explicit.

## Endpoint reference

| Vouch controller | Purpose |
| --- | --- |
| `SessionsController` | Check credentials and sign in or sign out. |
| `MembershipSessionsController` | Select a membership after its parent account signs in. Used by linked membership scopes. |
| `RegistrationsController` | Create the credentials record and run your registration customization. |
| `PasswordResetsController` | Send a reset link and accept a replacement password. |
| `TwoFactorChallengeController` | Check the second factor during sign-in. |
| `TwoFactorCredentialsController` | List, enroll, verify, and remove second-factor credentials. The generator supplies enrollment actions for your credential model. |
| `RecoveryCodesController` | Display remaining recovery codes and generate a replacement set for an authenticated account or owned credential. |
| `OmniAuthsController` | Handle provider sign-in, registration, and account linking. |
| `InvitationsController` | Invite someone, accept an invitation, or revoke it. |
| `ImpersonationsController` | Switch to an authorized target and restore the original signed-in user. |

## Routes

These routes use `auth.scope model: "User"` with the corresponding feature declarations. Optional feature generators add their declarations. Every named `_path` helper also has a Rails `_url` variant.

| Declaration | Request | Helper | Action |
| --- | --- | --- | --- |
| `auth.sessions` | `GET /users/sign_in` | `new_user_session_path` | `Users::SessionsController#new` |
| | `POST /users/sign_in` | `user_session_path` | `Users::SessionsController#create` |
| | `DELETE /users/sign_out` | `user_sign_out_path` | `Users::SessionsController#destroy` |
| `auth.registrations` | `GET /users/sign_up` | `new_user_registration_path` | `Users::RegistrationsController#new` |
| | `POST /users/sign_up` | `user_registration_path` | `Users::RegistrationsController#create` |
| `auth.password_resets` | `GET /users/password_reset/new` | `new_user_password_reset_path` | `Users::PasswordResetsController#new` |
| | `POST /users/password_reset` | `user_password_reset_path` | `Users::PasswordResetsController#create` |
| | `GET /users/password_reset/edit?token=…` | `edit_user_password_reset_path(token: token)` | `Users::PasswordResetsController#edit` |
| | `PATCH/PUT /users/password_reset` | `user_password_reset_path` | `Users::PasswordResetsController#update` |
| `auth.two_factor` | `GET /users/two_factor_challenges` | `user_two_factor_challenges_path` | `Users::TwoFactorChallengeController#index` |
| | `GET /users/two_factor_challenges/:id` | `user_two_factor_challenge_path(id)` | `Users::TwoFactorChallengeController#show` |
| | `POST /users/two_factor_challenges/:id/send_code` | `send_code_user_two_factor_challenge_path(id)` | `Users::TwoFactorChallengeController#send_code` |
| | `PATCH/PUT /users/two_factor_challenges/:id` | `user_two_factor_challenge_path(id)` | `Users::TwoFactorChallengeController#update` |
| | `GET /users/two_factor_credentials` | `user_two_factor_credentials_path` | `Users::TwoFactorCredentialsController#index` |
| | `GET /users/two_factor_credentials/new` | `new_user_two_factor_credential_path` | `Users::TwoFactorCredentialsController#new` |
| | `POST /users/two_factor_credentials` | `user_two_factor_credentials_path` | `Users::TwoFactorCredentialsController#create` |
| | `PATCH/PUT /users/two_factor_credentials/:id` | `user_two_factor_credential_path(id)` | `Users::TwoFactorCredentialsController#update` |
| | `DELETE /users/two_factor_credentials/:id` | `user_two_factor_credential_path(id)` | `Users::TwoFactorCredentialsController#destroy` |
| `auth.two_factor` | `GET /users/recovery` | `user_recovery_two_factor_challenge_path` | `Users::TwoFactorChallengeController#recovery` |
| | `POST /users/recovery` | `user_consume_recovery_two_factor_challenge_path` | `Users::TwoFactorChallengeController#consume_recovery` |
| | `GET /users/recovery_codes` | `user_recovery_codes_path` | `Users::RecoveryCodesController#show` |
| | `POST /users/recovery_codes` | `user_recovery_codes_path` | `Users::RecoveryCodesController#create` |
| `auth.oauth_callbacks` | `GET /users/auth/:provider/callback` | No named helper | `Users::OmniAuthsController#callback` |
| | `GET /users/auth/failure` | `users_auth_failure_path` | `Users::OmniAuthsController#failure` |
| `auth.invitations` | `GET /users/invitation/new` | `new_user_invitation_path` | `Users::InvitationsController#new` |
| | `POST /users/invitation` | `user_invitation_path` | `Users::InvitationsController#create` |
| | `GET /users/invitation/accept?token=…` | `accept_user_invitation_path(token: token)` | `Users::InvitationsController#accept` |
| | `DELETE /users/invitation` | `user_invitation_path` | `Users::InvitationsController#destroy` |
| `auth.impersonation` | `POST /users/impersonations/:id` | `user_impersonate_path(id)` | `Users::ImpersonationsController#create` |
| | `DELETE /users/impersonations` | `user_stop_impersonation_path` | `Users::ImpersonationsController#destroy` |
| | `DELETE /users/impersonations/all` | `user_stop_all_impersonations_path` | `Users::ImpersonationsController#destroy_all` |

For a linked membership scope, the three session routes use `Users::SessionsController < Vouch::MembershipSessionsController`. Credential routes such as password reset belong to its parent account scope and use `/accounts` and `account_` prefixes. See [model mapping](model-mapping.md).

OAuth request URLs are provided by OmniAuth; [the OAuth guide](oauth.md) shows the sign-in button and provider configuration. Callback methods can vary by provider.

Use `bin/rails routes` to inspect your enabled routes. [Custom prefixes](model-mapping.md) change URLs and route helper names independently.

## Registration

Override record construction when signup creates an organisation and membership. `build_tenant(account)` and `build_identity(account, tenant:)` return unsaved records; Vouch saves them in the registration transaction.

```ruby
class Accounts::RegistrationsController < Vouch::RegistrationsController
  private

  def build_tenant(account)
    Organisation.new(params.require(:organisation).permit(:name))
  end

  def build_identity(account, tenant:)
    tenant.users.build(account: account)
  end
end
```

Add accompanying database records with a transactional hook:

```ruby
class Accounts::RegistrationsController < Vouch::RegistrationsController
  after_sign_up do |account, identity|
    Preferences.create!(account: account)
  end
end
```

`Preferences` is an example model you supply. Invited registration uses the existing membership, then runs registration hooks in the same transaction. Existing accounts accepting another invitation use the invitation-acceptance hooks instead. [Invitations](invitations.md#registration-customization) shows both cases; [OAuth](oauth.md#create-an-organisation-during-signup) shows sharing construction methods with provider signup.

## Eject a controller

Use a subclass override or [hook](sessions-and-hooks.md) for small changes. Eject when you want the full endpoint actions editable in your application:

```sh
bin/rails generate vouch:eject users sessions
```

This creates a local implementation controller and points your existing controller at it:

```ruby
# app/controllers/users/sessions_implementation_controller.rb
class Users::SessionsImplementationController < ApplicationController
  include Vouch::Authentication

  # Full copied actions and their supporting methods are in this file.
end
```

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Users::SessionsImplementationController
  # Your existing overrides stay here; super calls the local implementation.
end
```

Edit either local file. The route still points to `Users::SessionsController`. Keeping the local implementation as its superclass preserves your overrides, `super` calls and generated enrollment customizations. Re-running the generator does not replace the local implementation.

For a linked membership scope, ejecting its generated `SessionsController` copies membership selection rather than password authentication.

The copied actions still use `Vouch::Authentication` and the gem's model/session services. Ejection gives you ownership of the controller implementation; it does not copy the whole gem into your application.

For a custom namespace, supply the authentication scope:

```sh
bin/rails generate vouch:eject portal sessions --auth-scope user
```

Connect it in the scope's route block:

```ruby
auth.sessions controller: "portal/sessions"
```

Supported endpoints include `sessions`, `membership_sessions`, `registrations`, `password_resets`, `invitations`, `two_factor_challenge`, `two_factor_credentials`, `recovery_codes`, `omni_auths` and `impersonations`.
