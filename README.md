# Vouch

Vouch provides authentication for Rails applications: password sign-in, registration, password reset, MFA, OAuth, invitations, and impersonation. Use one model for a single-tenant application, or separate accounts and memberships for multi-tenant applications.

Your application owns its models, views, email delivery, and authorization rules.

## Requirements

- Rails 8.x and a Ruby version supported by your Rails version (at least Ruby 3.2).
- PostgreSQL is the database used by the test suite.

## Installation

Add Vouch to your Gemfile:

```ruby
gem "rails_vouch"
```

Then install it and generate a single-model login:

```sh
bundle install
bin/rails generate vouch:install
bin/rails generate vouch:scope users User --single-model
bin/rails db:migrate
```

The generators create the `User` model and migration, sign-in and registration controllers and views, and authentication routes. The model includes password authentication, email normalization, and email validation.

The generated routes include:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

| Action | URL | Route helper |
| --- | --- | --- |
| Sign-in form | `GET /users/sign_in` | `new_user_session_path` |
| Sign in | `POST /users/sign_in` | `user_session_path` |
| Sign-up form | `GET /users/sign_up` | `new_user_registration_path` |
| Register | `POST /users/sign_up` | `user_registration_path` |
| Sign out | `DELETE /users/sign_out` | `user_sign_out_path` |

Use these helpers wherever your application offers authentication controls:

```erb
<%= link_to "Sign in", new_user_session_path %>
<%= link_to "Sign up", new_user_registration_path %>
<%= button_to "Sign out", user_sign_out_path, method: :delete %>
```

Successful sign-in and registration default to your application's `root_path`. [Redirect customization](#redirects) lets you choose other destinations.

## Protecting application pages

Vouch automatically includes `Vouch::ApplicationHelpers` in Rails controllers. This concern defines `current_user`, `user_signed_in?`, and `authenticate_user!` for the generated user scope. The current-user helper and signed-in predicate are also available in views.

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

Keep authentication requirements out of `ApplicationController`, because Vouch's sign-in and registration endpoints inherit it too. Use a separate base such as `AuthenticatedController`, or add the guard to individual controllers.

For this single-model setup, `current_user` returns the authenticated `User`. There is no additional account helper.

## Multi-tenant authentication

For accounts with memberships in organisations, generate separate models:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
bin/rails db:migrate
```

This creates `Account` for credentials, `User` for memberships, and `Organisation` for tenants. `Account` has many users; each user belongs to an account and an organisation. Account registration creates an initial membership and organisation; adapt the generated registration fields to your application.

The generated routes link the membership scope to the account scope:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :account, model: "Account" do
    auth.sessions
    auth.registrations
  end

  auth.scope :user, account_scope: :account,
    identity: "User", tenant: "Organisation" do
    auth.sessions
  end
end
```

Account authentication checks credentials and any required MFA. A user membership session then selects an eligible membership: zero memberships denies access, one is selected automatically, and several produce a selection form. The email identifies the account; it does not independently choose an organisation.

A protected membership page starts this sequence automatically. Signing in directly at `/accounts/sign_in` establishes only the account session and uses its configured redirect.

| Requirement | Guard | Current record |
| --- | --- | --- |
| Authenticated account | `authenticate_account!` | `current_account` |
| Selected user membership | `authenticate_user!` | `current_account_user`, also available as `current_user` |

Use `current_user.organisation` to access the selected tenant. `current_account.users` is the account's collection of memberships, not the session's selected membership.

Signing out of a membership leaves the account authenticated. Signing out of the account also clears its dependent membership sessions.

See [model mapping](docs/model-mapping.md) for schemas, associations, and tenant constraints.

## Authentication scopes

A scope names an authentication context. Tenancy is a separate choice: a scope can authenticate a single model or select a membership belonging to a tenant.

For example, an account may have separate user and administrator memberships:

```ruby
auth.scope :admin, account_scope: :account,
  identity: "Admin", tenant: "Organisation" do
  auth.sessions
end
```

This adds `authenticate_admin!`, `current_account_admin`, and the `current_admin` shortcut. A user session does not satisfy the admin guard. The application decides which memberships and actions are authorized; the name `admin` does not grant permissions.

Scope names determine session and helper names. `auth.scope model: "User"` infers `:user`; `Admin::Account` infers `:admin_account`. Give an explicit scope name when the same model serves more than one authentication context. Conflicting generated helper names raise a configuration error.

See [model mapping](docs/model-mapping.md) for shared versus separate administrator credentials.

## Redirects

Define shared defaults in `ApplicationController` using your application's route helpers:

```ruby
class ApplicationController < ActionController::Base
  protected

  def after_sign_in_path_for(record, scope:)
    projects_path
  end

  def after_sign_up_path_for(record, scope:)
    onboarding_path
  end

  def after_sign_out_path_for(scope:)
    welcome_path
  end
end
```

The record is the account or membership whose authentication just completed. The scope identifies that authentication context. Registration remains registration when completion passes through MFA and membership selection.

You can also override `after_sign_in_path`, `after_sign_up_path`, or `after_sign_out_path` in an individual endpoint controller. That override takes precedence when that controller finishes the flow. For sign-in, a previously requested protected page takes precedence over the fallback destination.

See [controllers and routes](docs/controllers.md) for examples and the complete route reference.

## Feature guides

- [Setup and generators](docs/setup.md)
- [Controllers and routes](docs/controllers.md)
- [Model mapping](docs/model-mapping.md)
- [Password reset and recovery](docs/passwords-and-recovery.md)
- [Verification and MFA](docs/verification-and-mfa.md)
- [OAuth](docs/oauth.md)
- [Invitations](docs/invitations.md)
- [Impersonation](docs/impersonation.md)
- [Sessions and lifecycle hooks](docs/sessions-and-hooks.md)
- [Authentication policy](docs/authentication-policy.md)

Advanced integration references: [persistence](docs/persistence.md), [Warden](docs/warden.md), [credential adapter tests](docs/credential-adapter-contract.md), and [schema changes](docs/upgrading.md).

## Development

```sh
bundle install
RAILS_ENV=test bundle exec rake app:db:prepare
bundle exec rspec
```

The development Gemfile uses sibling `active_hooks` and `otp_courier` checkouts. Set `VOUCH_RELEASE_DEPS=1` when installing and running against published dependencies instead.

See the [changelog](CHANGELOG.md). Vouch is available under the [MIT License](LICENSE.txt).
