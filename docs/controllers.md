# Controllers and routes

## Contents

- [Protect pages](#protect-pages)
- [Customize an authentication endpoint](#customize-an-authentication-endpoint)
- [Customize action responses](#customize-action-responses)
- [Endpoint reference](#endpoint-reference)
- [Routes](#routes)
- [Registration](#registration)
- [Eject a controller](#eject-a-controller)

After the [README setup](../README.md#install-and-generate-a-login), your application has two endpoint subclasses (`Users::SessionsController` and `Users::RegistrationsController`) and their sign-in, registration and identity-confirmation views. Optional feature generators add their own controllers and views.

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

Vouch automatically includes `Vouch::ApplicationHelpers` in application controllers. This supplies `authenticate_user!`, `current_user`, and `user_signed_in?` for the `:user` scope, and exposes the current-record helpers to views. For a [configured membership scope](model-mapping.md#multi-tenant-models), where `User` belongs to the credentials-owning `Account`, `authenticate_user!` checks both the account login and the selected user membership. You do not need a second account filter.

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

## Customize action responses

Call `super` to perform the operation, then render, redirect or call `head` in your action. The action returns a status symbol and exposes the prepared records as instance variables:

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::SessionsController
  def create
    status = super
    return unless request.format.json?

    http_status = case status
    when :ok then :ok
    when :pending then :accepted
    else :unprocessable_entity
    end

    render json: { status: status, next_step: @next_step }, status: http_status
  end
end
```

Vouch waits until your whole action returns before sending its default response. Rails calls the controller's `default_render` only when no response has been performed. In this example JSON gets your response and HTML retains Vouch's normal redirect or validation page. Permission checks belong before `super`, because the operation has already happened when it returns.

| Status | Meaning |
| --- | --- |
| `:ok` | The operation completed. |
| `:pending` | Another step is required; `@next_step` identifies it, such as `:two_factor` or `:selection`. |
| `:invalid` | The submitted fields, credentials, selection or continuation were rejected. |
| `:cancelled` | A callback or persistence operation cancelled the change. |
| `:locked` | The credential's attempt limit prevents this attempt. |
| `:already_verified` | The verification subject was already verified and saved. |

These statuses apply to operation actions. An ordinary page action, such as registration `new`, prepares variables and uses Rails template rendering; its return value has no outcome contract. Authentication guards can respond before an action runs.

### Records and errors

The configured authentication scope determines the current operation's record variable:

| Configuration | Prepared variables |
| --- | --- |
| Single-model `:user` scope | `@user` |
| `:operator` scope backed by `User` | `@operator` |
| `:user` membership linked to `:account` | `@account`, `@user`; membership selection exposes `@users` |
| MFA enrollment or challenge | `@credential`, alongside the credentials-scope record |
| Generic verification | `@verifiable` |
| Invitation | `@invitation` |
| Recovery-code generation | `@recovery_owner`, `@recovery_codes` |

These are operation records, not authenticated-current-record helpers: a failed registration can expose an unsaved `@user`. Keep using `current_user` to ask who is signed in. Resource-specific variables retain their names when the authentication scope has another name.

Use the record's `errors` for validation messages. `@operation_error` holds an expected exception when available, and `@failure_reason` gives an operation-specific reason. They may be nil. Unexpected exceptions still reach Rails error handling. Registration also exposes `@registration_committed`, so an unsuccessful sign-in after account creation does not look like failed creation.

> Scope names must not collide with Rails state or endpoint variables such as `request`, `credential` or `recovery_codes`. Vouch checks these names when routes load and raises `Vouch::ConfigurationError` with the conflicting variable. Parent and membership names must also produce distinct variables, including the membership collection: use `:account` and `:user`, for example, rather than `:users` and `:user`.

### Change the fallback

Override `default_render` if you want to change the controller's default response while retaining action overrides:

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::SessionsController
  private

  def default_render
    if action_name == "create" && @operation_status == :invalid
      render :new, status: :unprocessable_entity
    else
      super
    end
  end
end
```

A host action that already renders, redirects or calls `head` bypasses this fallback. [Registration](registration.md#custom-registration-forms) also accepts a block to save your records inside its transaction; that block is separate from response handling. Model methods keep their normal and bang APIs and their [`Vouch::Result` values](persistence.md).

## Endpoint reference

| Vouch controller | Purpose |
| --- | --- |
| `SessionsController` | Check credentials, sign in or out, and confirm identity for [sensitive actions](authentication-policy.md#confirm-identity-before-a-sensitive-action). |
| `MembershipSessionsController` | Select a membership after its parent account signs in. Used by linked membership scopes. |
| `RegistrationsController` | Create the credentials record and run your registration customization. |
| `PasswordResetsController` | Send a reset link and accept a replacement password. |
| `TwoFactorChallengeController` | Check the second factor during sign-in. |
| `TwoFactorCredentialsController` | List, enroll, verify, and remove second-factor credentials. The generator supplies enrollment actions for your credential model. |
| `RecoveryCodesController` | Display remaining recovery codes and generate a replacement set for an authenticated account or owned credential. |
| `OmniAuthsController` | Handle provider sign-in, registration, and account linking. |
| `InvitationsController` | Invite someone, resend, accept, reject, or revoke an invitation. |
| `ImpersonationsController` | Switch to an authorized target and restore the original signed-in user. |

## Routes

The standard declarations accept route options. `paths:` changes URL segments.
`path_names:` supplies the complete helper basename for an action; it does not
change the controller action. `as:` changes the normal scope helper prefix:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  Vouch.routes(self) do |auth|
    auth.scope model: "User", path: "accounts", as: "account" do
      auth.sessions(
        paths: {
          new: "login",
          create: "login",
          destroy: "logout"
        },
        path_names: {
          new: :sign_in,
          create: :create_session,
          destroy: :sign_out
        }
      )
      auth.registrations
    end
  end
end
```

This produces `sign_in_path` for `GET /accounts/login`,
`create_session_path` for `POST /accounts/login`, and `sign_out_path` for
`DELETE /accounts/logout`. The explicit `path_names:` values replace the
usual `account_` helper prefix. Use the generated form helpers or
`vouch_route_path(:sessions, :create)` and
`vouch_route_path(:registrations, :create)` when an application configures
nonstandard paths.

`auth.password_resets`, `auth.invitations`, and `auth.impersonation` accept the same options, keyed by their controller actions. For example:

```ruby
# config/routes.rb, inside auth.scope model: "User"
auth.invitations(
  paths: { accept: "join", resend: "resend-invitation" },
  path_names: { accept: :join_team, resend: :resend_invitation }
)
```

This creates `join_team_path` at `/users/join` for both viewing and accepting an invitation. Generated forms and mailers follow the configured names. When two actions normally share a helper, such as password-reset `create` and `update`, give them different `path_names` if their paths differ.

OAuth callback paths are full paths, including the scope prefix:

```ruby
# config/routes.rb, inside auth.scope model: "User"
auth.oauth_callbacks(
  paths: { callback: "/users/providers/:provider/return" },
  path_names: { callback: :provider_return }
)
```

The provider middleware and registered provider callback URL must use that same path.

MFA has separate `auth.two_factor_challenges`, `auth.two_factor_credentials` and `auth.recovery_codes` declarations. Each accepts `controller:`, `paths:` and `path_names:` with the action names in the table below. [The MFA guide](mfa.md#configure-challenge-and-management-routes) shows how to customize them.

These routes use `auth.scope model: "User"` with the corresponding feature declarations. Optional feature generators add their declarations. Every named `_path` helper also has a Rails `_url` variant.

| Declaration | Request | Helper | Action |
| --- | --- | --- | --- |
| `auth.sessions` | `GET /users/sign_in` | `new_user_session_path` | `Users::SessionsController#new` |
| | `POST /users/sign_in` | `user_session_path` | `Users::SessionsController#create` |
| | `GET /users/confirmation` | `new_user_confirmation_path` | `Users::SessionsController#confirmation` |
| | `POST /users/confirmation` | `user_confirmation_path` | `Users::SessionsController#confirm` |
| | `DELETE /users/confirmation` | `cancel_user_confirmation_path` | `Users::SessionsController#cancel_confirmation` |
| | `DELETE /users/sign_out` | `user_sign_out_path` | `Users::SessionsController#destroy` |
| `auth.registrations` | `GET /users/sign_up` | `new_user_registration_path` | `Users::RegistrationsController#new` |
| | `POST /users/sign_up` | `user_registration_path` | `Users::RegistrationsController#create` |
| `auth.password_resets` | `GET /users/password_reset/new` | `new_user_password_reset_path` | `Users::PasswordResetsController#new` |
| | `POST /users/password_reset` | `user_password_reset_path` | `Users::PasswordResetsController#create` |
| | `GET /users/password_reset/edit?token=…` | `edit_user_password_reset_path(token: token)` | `Users::PasswordResetsController#edit` |
| | `PATCH/PUT /users/password_reset` | `user_password_reset_path` | `Users::PasswordResetsController#update` |
| `auth.two_factor_challenges` | `GET /users/two_factor_challenges` | `user_two_factor_challenges_path` | `Users::TwoFactorChallengeController#index` |
| | `DELETE /users/two_factor_challenges` | `user_two_factor_challenges_path` | `Users::TwoFactorChallengeController#destroy` |
| | `GET /users/two_factor_challenges/:id` | `user_two_factor_challenge_path(id)` | `Users::TwoFactorChallengeController#show` |
| | `POST /users/two_factor_challenges/:id/send_code` | `send_code_user_two_factor_challenge_path(id)` | `Users::TwoFactorChallengeController#send_code` |
| | `PATCH/PUT /users/two_factor_challenges/:id` | `user_two_factor_challenge_path(id)` | `Users::TwoFactorChallengeController#update` |
| `auth.two_factor_credentials` | `GET /users/two_factor_credentials` | `user_two_factor_credentials_path` | `Users::TwoFactorCredentialsController#index` |
| | `GET /users/two_factor_credentials/new` | `new_user_two_factor_credential_path` | `Users::TwoFactorCredentialsController#new` |
| | `POST /users/two_factor_credentials` | `user_two_factor_credentials_path` | `Users::TwoFactorCredentialsController#create` |
| | `GET /users/two_factor_credentials/:id/edit` | `edit_user_two_factor_credential_path(id)` | `Users::TwoFactorCredentialsController#edit` |
| | `POST /users/two_factor_credentials/:id/send_code` | `send_code_user_two_factor_credential_path(id)` | `Users::TwoFactorCredentialsController#send_code` |
| | `PATCH/PUT /users/two_factor_credentials/:id` | `user_two_factor_credential_path(id)` | `Users::TwoFactorCredentialsController#update` |
| | `DELETE /users/two_factor_credentials/:id` | `user_two_factor_credential_path(id)` | `Users::TwoFactorCredentialsController#destroy` |
| `auth.two_factor_challenges` | `GET /users/recovery` | `user_recovery_two_factor_challenge_path` | `Users::TwoFactorChallengeController#recovery` |
| | `POST /users/recovery` | `user_consume_recovery_two_factor_challenge_path` | `Users::TwoFactorChallengeController#consume_recovery` |
| `auth.recovery_codes` | `GET /users/recovery_codes` | `user_recovery_codes_path` | `Users::RecoveryCodesController#show` |
| | `POST /users/recovery_codes` | `user_recovery_codes_path` | `Users::RecoveryCodesController#create` |
| `auth.oauth_callbacks` | `GET /users/auth/:provider/callback` | `user_oauth_callback_path(provider: :github)` | `Users::OmniAuthsController#callback` |
| | `GET /users/auth/failure` | `user_oauth_failure_path` | `Users::OmniAuthsController#failure` |
| `auth.invitations` | `GET /users/invitation/new` | `new_user_invitation_path` | `Users::InvitationsController#new` |
| | `POST /users/invitation` | `user_invitation_path` | `Users::InvitationsController#create` |
| | `GET/POST /users/invitation/accept?token=…` | `accept_user_invitation_path(token: token)` | `Users::InvitationsController#accept` |
| | `POST /users/invitation/reject` | `reject_user_invitation_path` | `Users::InvitationsController#reject` |
| | `POST /users/invitation/resend` | `resend_user_invitation_path` | `Users::InvitationsController#resend` |
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
# app/controllers/accounts/registrations_controller.rb
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
# app/controllers/accounts/registrations_controller.rb
class Accounts::RegistrationsController < Vouch::RegistrationsController
  after_sign_up do |account, identity|
    Preferences.create!(account: account)
  end
end
```

> `Preferences` is an example model you supply.

Invited registration uses the existing membership, then runs registration hooks in the same transaction. Existing accounts accepting another invitation use the invitation-acceptance hooks instead. [Invitations](invitations.md#registration-customization) shows both cases; [Registration](registration.md#construct-records-transactionally) shows sharing construction methods with provider signup.

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

The copied implementation includes `default_render`, so action overrides can still choose a response after `super`. Edit that local fallback to change the default response too.

The optional `verifications` and `temporary_verifications` controllers can also be ejected. They use host-prepared records rather than an authentication scope; see the [verification guide](verification.md#results-and-customization) for their shared superclass.

For a linked membership scope, ejecting its generated `SessionsController` copies membership selection rather than password authentication.

The copied actions still use `Vouch::Authentication` and the gem's model/session services. Ejection gives you ownership of the controller implementation; it does not copy the whole gem into your application.

For a custom namespace, supply the authentication scope:

```sh
bin/rails generate vouch:eject portal sessions --auth-scope user
```

Connect it in the scope's route block:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  Vouch.routes(self) do |auth|
    auth.scope model: "User" do
      auth.sessions controller: "portal/sessions"
    end
  end
end
```

Supported endpoints include `sessions`, `membership_sessions`, `registrations`, `password_resets`, `invitations`, `two_factor_challenge`, `two_factor_credentials`, `recovery_codes`, `omni_auths` and `impersonations`.

Feature generators already place their generated views and mailers in your application, so edit those files directly; they do not need controller ejection. For example, the password-reset generator writes its forms under `app/views/users/password_resets/` and a mailer under `app/mailers/`.

| What you want to change | Where to change it |
| --- | --- |
| Generated forms and page markup | The generated files in `app/views/`. |
| Generated mail content or delivery method | The generated mailer/template or model delivery method shown in that feature's guide. |
| Endpoint actions, callbacks and prepared records | Your subclass, or its local implementation after ejection. |
| Mapping, authentication session and credential behavior | The documented runtime extension points; ejection does not copy these modules. |

An existing hand-written controller using nested `module` declarations must be rewritten with a `class Users::SessionsController < ...` declaration before ejection; the generator reports this unsupported source shape rather than overwriting it.
