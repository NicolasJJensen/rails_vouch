# Vouch

Vouch adds conventional Rails authentication: password sign-in, registration, password resets, MFA, recovery codes, OAuth, invitations, and support impersonation. It generates the controllers and views into your application, where ordinary changes remain yours to make.

## Contents

- [Install and generate a login](#install-and-generate-a-login)
- [Protect pages](#protect-pages)
- [Use the generated routes](#use-the-generated-routes)
- [Customize redirects](#customize-redirects)
- [Add features](#add-features)
- [Use a shared account and memberships](#use-a-shared-account-and-memberships)
- [Go further](#go-further)
- [Development](#development)

## Install and generate a login

Vouch requires Rails 8.x and Ruby 3.2 or newer, subject to your Rails version’s requirements.

```sh
bundle add rails_vouch
bin/rails generate vouch:install
bin/rails generate vouch:scope User
bin/rails db:migrate
```

The scope generator creates a `User`, sign-in and registration controllers,
forms, routes, and this standard credential schema. The generated model
normalizes and validates `email_address` and uses `has_secure_password`.

```ruby
create_table :users do |t|
  t.string :email_address, null: false
  t.string :password_digest, null: false
  t.bigint :auth_session_version, null: false, default: 0
  t.timestamps
  t.index "lower(email_address)", unique: true, name: "index_users_on_lower_email_address"
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
class AuthenticatedController < ApplicationController
  before_action :authenticate_user!
end

class ProjectsController < AuthenticatedController
  def index
    @projects = current_user.projects
  end
end
```

Vouch automatically includes `Vouch::ApplicationHelpers` in application controllers. It supplies `authenticate_user!`, `current_user`, and `user_signed_in?`, and exposes current-user and signed-in helpers to views. After sign-in, a visitor returns to the protected page they requested.

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
class Users::SessionsController < Vouch::SessionsController
  private

  def after_sign_in_path
    projects_path
  end
end
```

[Controllers and routes](docs/controllers.md#redirects) explains shared redirects, route customization, and ejection when you need to own an endpoint action.

## Add features

Each feature guide starts with its generator, migration, supplied pages, and ordinary extension points.

- [Password reset](docs/password-reset.md) and [password history](docs/password-history.md)
- [Verification](docs/verification.md), [MFA](docs/mfa.md), [recovery codes](docs/recovery-codes.md), and [passwordless sign-in](docs/passwordless.md)
- [OAuth sign-in](docs/oauth.md)
- [Invitations](docs/invitations.md)
- [Impersonation for support access](docs/impersonation.md)
- [Lockout](docs/lockout.md)

## Use a shared account and memberships

For an application where one person can belong to organisations, generate a credential `Account` and a `User` membership:

```sh
bin/rails generate vouch:scope User --account Account --tenant Organisation
bin/rails db:migrate
```

The generated configuration uses nested declarations. Names are inferred from the models, so the standard declaration needs no explicit scope names:

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

## Go further

- [Registration and sign-in customization](docs/sign-in-customization.md)
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
