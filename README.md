# Vouch

Vouch adds conventional Rails authentication: password sign-in, registration, password resets, MFA, recovery codes, OAuth, invitations, and support impersonation. It generates the controllers and views into your application, where ordinary changes remain yours to make.

## Contents

- [Install and generate a login](#install-and-generate-a-login)
- [Protect pages](#protect-pages)
- [Use the generated routes](#use-the-generated-routes)
- [Customize redirects](#customize-redirects)
- [Add features](#add-features)
- [Use a shared account and memberships](#use-a-shared-account-and-memberships)
- [Customization and reference](#customization-and-reference)
- [Development](#development)

## Install and generate a login

Vouch supports Rails 8.1 and newer Rails 8 releases, Ruby 3.2 or newer, and PostgreSQL.

For a new `User` model:

```sh
bundle add rails_vouch
bin/rails generate vouch:install
bin/rails generate vouch:scope User
bin/rails db:migrate
```

The install generator adds `config/initializers/vouch.rb`, translations and a routes block. The scope generator adds:

- A `User` model with `Vouch::Authenticatable`, `has_secure_password`, and email normalization and validation.
- A migration with the columns below.
- `Users::SessionsController` and `Users::RegistrationsController`, which inherit Vouch's endpoint actions.
- Sign-in and registration views and their routes.

> Already have a `User` model? The generator preserves it. Add the [existing-model prerequisites](docs/model-mapping.md#existing-models) before using the endpoints.

```ruby
enable_extension "citext" unless extension_enabled?("citext")

create_table :users do |t|
  t.citext :email_address, null: false, index: { unique: true }
  t.string :password_digest
  t.bigint :auth_session_version, null: false, default: 0
  t.timestamps
end
```

It also adds a route declaration:

```ruby
Vouch.routes(self) do |auth|
  auth.scope model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

## Protect pages

Put access control on a base controller. Keep `ApplicationController` public: generated sign-in and registration endpoints inherit from it.

```ruby
# app/controllers/authenticated_controller.rb
class AuthenticatedController < ApplicationController
  before_action :authenticate_user!
end

# app/controllers/projects_controller.rb
class ProjectsController < AuthenticatedController
  def index
    @projects = current_user.projects
  end
end
```

Vouch automatically includes `Vouch::ApplicationHelpers` in application controllers. It supplies `authenticate_user!`, `current_user`, and `user_signed_in?`, and exposes current-user and signed-in helpers to views. After sign-in, a visitor returns to a protected GET page they requested; otherwise Vouch uses your sign-in redirect, which defaults to the root route. `projects` is an example association supplied by your application.

## Use the generated routes

| Action | Request | Helper |
| --- | --- | --- |
| Sign-in form | `GET /users/sign_in` | `new_user_session_path` |
| Sign in | `POST /users/sign_in` | `user_session_path` |
| Registration form | `GET /users/sign_up` | `new_user_registration_path` |
| Register | `POST /users/sign_up` | `user_registration_path` |
| Sign out | `DELETE /users/sign_out` | `user_sign_out_path` |

```erb
<%= link_to "Sign in", new_user_session_path %>
<%= link_to "Sign up", new_user_registration_path %>
<%= button_to "Sign out", user_sign_out_path, method: :delete %>
```

## Customize redirects

The generated controller is the usual place to set an application destination:

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::SessionsController
  private

  def after_sign_in_path
    projects_path
  end
end
```

[Controllers and routes](docs/controllers.md#redirects) explains shared redirects, route customization, and ejection when you need to own an endpoint action.

## Add features

Choose an optional feature for its setup and customization guide.

- [Password reset](docs/password-reset.md) and [password history](docs/password-history.md)
- [Verification](docs/verification.md), [MFA](docs/mfa.md), [recovery codes](docs/recovery-codes.md), and [passwordless sign-in](docs/passwordless.md)
- [OAuth sign-in](docs/oauth.md)
- [Invitations](docs/invitations.md)
- [Impersonation for support access](docs/impersonation.md)
- [Lockout](docs/lockout.md)

## Use a shared account and memberships

For a multi-tenant application, an `Account` can hold the sign-in credentials while each `User` represents membership in an `Organisation`. These are example model names. This is an alternative initial setup to the single `User` above, not a conversion command for an existing installation:

```sh
bin/rails generate vouch:scope User --account Account --tenant Organisation
bin/rails db:migrate
```

The account has sign-in and registration routes. Its nested membership has a route for entering an organisation:

```ruby
Vouch.routes(self) do |auth|
  auth.scope model: "Account" do
    auth.sessions
    auth.registrations

    auth.membership model: "User", tenant: "Organisation" do
      auth.sessions
    end
  end
end
```

`Account` owns email, password, MFA, and session invalidation. `User` belongs to the account and organisation. Registration creates the account, organisation, and first membership in one transaction. `authenticate_user!` requires both the account and selected membership; `authenticate_account!` is for account-only settings.

See [the generated models and schema](docs/model-mapping.md#multi-tenant-models) for this setup, and [separate administrator logins](docs/model-mapping.md#separate-administrator-logins) when your application needs another authentication scope.

## Customization and reference

- [Registration](docs/registration.md), including [custom registration forms](docs/registration.md#custom-registration-forms), and [sign-in customization](docs/sign-in-customization.md)
- [Controllers, route paths, and ejection](docs/controllers.md)
- [Models, primary keys, and advanced scopes](docs/model-mapping.md)
- [Authentication policy and session invalidation](docs/authentication-policy.md)
- [Sessions, Warden, and lifecycle hooks](docs/sessions-and-hooks.md)
- [Custom authentication endpoints](docs/advanced-custom-authentication.md)
- [Advanced persistence](docs/persistence.md) and [existing Warden middleware](docs/warden.md)

## Development

```sh
bundle install
RAILS_ENV=test bundle exec rake app:db:prepare
bundle exec rspec
```

The suite uses PostgreSQL. The development Gemfile uses sibling `active_hooks` and `otp_courier` checkouts; set `VOUCH_RELEASE_DEPS=1` to use published dependencies.

[Changelog](CHANGELOG.md) · [MIT license](LICENSE.txt)
