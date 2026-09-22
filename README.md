# Vouch

Vouch is a Rails authentication engine built on Warden and ActiveRecord. It provides sign-in, registration, and optional authentication features while keeping your models, views, and application policies in your app.

Use one model for a conventional login, or separate accounts from application memberships when one person needs access to several organisations. Generated controllers and views give you a starting point that you can customize.

- Password authentication with optional resets, lockouts, and password history.
- Credential verification, magic-link integration, MFA, and recovery codes.
- OAuth integration, invitations, and impersonation.
- Separate logins for users and administrators, customizable controllers, and lifecycle hooks.

## Requirements

- Ruby 3.2 or newer, subject to your Rails version's Ruby requirements.
- Rails 8.x.
- PostgreSQL is the tested database. UUID primary keys are supported; composite primary keys are not.

Warden, BCrypt, `active_hooks`, and `otp_courier` are installed as dependencies. OAuth provider gems and TOTP libraries are optional; see the relevant feature guide before adding them.

## Installation and quick start

This example adds email and password sign-in with a new `User` model. If your application already has a user model or authentication system, read [advanced setup](docs/setup.md) before running the generators.

### Install the gem

Add to your `Gemfile`:

```ruby
gem "rails_vouch"
```

Then run:

```sh
bundle install
bin/rails generate vouch:install
```

The installer adds Vouch configuration, translations, and a route block to your application.

### Generate authentication

```sh
bin/rails generate vouch:scope users User --single-model
```

This creates the `User` model, a database migration, and controllers and views for sign-up and sign-in. It adds these routes to `config/routes.rb`:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

### Review the model and migrate

The generated model includes password authentication, email normalization, and validation:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password

  normalizes :email_address, with: ->(value) { value.strip.downcase }
  validates :email_address, presence: true, uniqueness: { case_sensitive: false }
end
```

The generated migration adds a unique index on the lowercase email address. Review the migration, then run:

```sh
bin/rails db:migrate
bin/rails vouch:verify
```

The verification task reports missing columns, associations, or configuration. You can edit the generated model and views to add your own validation rules and styling.

### Try it

Ensure your application has a `root` route: Vouch redirects there after sign-up and sign-in. The next section includes a protected home page example.

Start your Rails server and open `/users/sign_up` to create an account, or `/users/sign_in` to sign in. Password reset and other optional routes are added separately.

## Basic usage

Vouch automatically includes `Vouch::ApplicationHelpers` in Rails controllers, making its authentication helpers available in your `ApplicationController` and its subclasses. This module supplies `authenticate_user!`, `current_user`, and `user_signed_in?` for the user login configured above. `current_user` and `user_signed_in?` are also available in views.

### Protect a page

Add `before_action :authenticate_user!` to any controller that requires sign-in:

```ruby
# app/controllers/dashboard_controller.rb
class DashboardController < ApplicationController
  before_action :authenticate_user!

  def show
  end
end
```

Add `root "dashboard#show"` inside your application's routes block, alongside `Vouch.routes(self)`, and create `app/views/dashboard/show.html.erb`:

```erb
<p>Signed in as <%= current_user.email_address %></p>
<%= button_to "Sign out", user_sign_out_path, method: :delete %>
```

Visitors who are not signed in are redirected to the sign-in page. After signing in, they return to the page they requested.

### Access the signed-in user

Use these helpers in your controllers and views:

| Helper | Value |
| --- | --- |
| `current_user` | The signed-in `User`, or `nil`. |
| `user_signed_in?` | `true` when the user is signed in. |

For controller customization, see [controller integration](docs/controllers.md).

## Accounts, identities, and tenants

Use a single `User` model for a simple login system. If one person needs memberships in several organisations, use separate models:

| Role | Example | Purpose |
| --- | --- | --- |
| Account | `Account` | Owns the password and other credentials. |
| Identity | `User` | Represents an application membership. |
| Tenant (optional) | `Organisation` | Groups memberships within an organisation. |

For example, one `Account` can have a `User` membership in each of two organisations. The person signs in once, then chooses which membership to use.

In this setup, `current_user` returns the selected membership and `current_user_account` returns its account. With the single-model setup, both helpers return the same `User`. Separate account and identity models can also be used without an organisation model.

For a new application using this structure, use this generator **instead of** the single-model command:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
```

The routes for this setup include `auth.user_selection`, which lets a person choose a membership after signing in:

```ruby
Vouch.routes(self) do |auth|
  auth.scope account: "Account", identity: "User", tenant: "Organisation" do
    auth.sessions
    auth.registrations
    auth.user_selection
  end
end
```

Adapt the generated organisation fields and sign-up form to your application. See [setup](docs/setup.md) and [model mapping](docs/model-mapping.md) for custom model names, associations, and UUIDs.

## Separate logins with authentication scopes

An authentication scope is a named login within your application. Most applications need only the `:user` scope used above. Add another scope when you need independent logins—for example, a customer area and a staff portal, where signing into one should not sign you into the other.

Each scope has its own sign-in routes and session state. It also provides helpers named after the scope:

| Scope | Sign-in page | Authentication filter | Signed-in record |
| --- | --- | --- | --- |
| `:user` | `/users/sign_in` | `authenticate_user!` | `current_user` |
| `:admin` | `/admins/sign_in` | `authenticate_admin!` | `current_admin` |

This is also why the account helper is called `current_user_account`: it returns the account for the user login. An admin login has `current_admin_account`. A single `current_account` method would be ambiguous when both logins are active.

In `auth.scope :user, model: "User"`, `:user` names the login and `model:` identifies the model used for it. You can omit the name when it matches the model: `auth.scope model: "User"` uses `:user`. With separate account and identity models, Vouch derives the name from `identity:` instead.

An authentication scope is separate from an organisation or tenant. One user login can access several organisation memberships. Likewise, calling a scope `:admin` does not make its users administrators; your application still decides who may access the staff portal.

See [scope configuration](docs/model-mapping.md#scope-names) for custom names, namespaced models, and multiple logins using the same model.

## Optional features

Follow the setup guide for each feature you want to add.

| Feature | Vouch provides | Your application supplies |
| --- | --- | --- |
| [Password reset and history](docs/passwords-and-recovery.md) | Reset tokens, password history, and optional reset UI generation. | Delivery, password rules, and feature configuration. |
| [Lockouts and authentication policy](docs/authentication-policy.md) | Account lockouts and configurable sign-in rules. | Access rules and session-revocation policy. |
| [Verification and magic links](docs/verification-and-mfa.md) | Methods to issue and verify codes and sign-in links. | Delivery, controllers, routes, UI, and request limits. |
| [Multi-factor authentication](docs/verification-and-mfa.md) | Second-factor challenges and generated challenge screens. | Second-factor setup screens, delivery, and controls to enable or disable MFA. |
| [Recovery and backup codes](docs/passwords-and-recovery.md) | Code generation, hashed storage, and single-use consumption. | Code presentation and recovery UI. |
| [OAuth](docs/oauth.md) | Account-owned OAuth identities and callback controllers. | Provider configuration, routes, and registration/linking policy. |
| [Invitations](docs/invitations.md) | Invitation tokens, acceptance, revocation, and a generated controller and form. | Authorization, delivery, and account/membership creation rules. |
| [Impersonation](docs/impersonation.md) | Switching to another user and returning to the original user. | Authorization and application UI. |

Before enabling invitations or impersonation, define who is allowed to use them. For MFA, add a screen for users to set up their second factor. For magic links, provide the delivery method, controller, and views described in the guide.

## Customization and reference

Edit the generated models, controllers, and views to customize authentication. These guides cover configuration and more advanced integrations:

- [Advanced setup](docs/setup.md): feature generators, custom login identifiers, and configuration checks.
- [Controller integration](docs/controllers.md): subclasses, custom scopes, registration hooks, and controller ejection.
- [Model mapping](docs/model-mapping.md): relationship discovery and explicit association configuration.
- [Authentication policy](docs/authentication-policy.md): MFA requirements, lockouts, pending authentication, and revocation.
- [Sessions and lifecycle hooks](docs/sessions-and-hooks.md): session preservation, callbacks, and OAuth continuation.
- [Persistence contracts](docs/persistence.md): transactions, cancelled writes, and external effects.
- [Credential adapter contract](docs/credential-adapter-contract.md): shared RSpec examples for custom factors.
- [Existing Warden integration](docs/warden.md): middleware, reserved scopes, and failure handling.
- [Schema migration notes](docs/upgrading.md): adapting pre-release or manually maintained schemas.

## Development

The test suite uses PostgreSQL. By default, development uses sibling checkouts of `active_hooks` and `otp_courier`; set `VOUCH_RELEASE_DEPS=1` to use released dependencies:

```sh
VOUCH_RELEASE_DEPS=1 bundle install
RAILS_ENV=test VOUCH_RELEASE_DEPS=1 bundle exec rake app:db:prepare
VOUCH_RELEASE_DEPS=1 bundle exec rspec
```

Configure the test database in `spec/dummy/config/database.yml` or through your PostgreSQL environment variables. CI runs the suite against Rails 8.0 and 8.1. The suite covers authentication requests, sessions, generators, concurrent updates, and generated applications.

## Contributing

[Bug reports and pull requests](https://github.com/NicolasJJensen/rails_vouch) are welcome. Include reproduction steps and your Ruby, Rails, and database versions when reporting an issue.

## License

Vouch is available under the [MIT License](LICENSE.txt).
