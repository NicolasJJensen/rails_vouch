# Vouch

Vouch is a Rails authentication engine built on Warden and ActiveRecord. It provides sign-in, registration, and optional authentication features while keeping your models, views, and application policies in your app.

Use one model for a conventional login, or separate accounts from application memberships when one person needs access to several organisations. Generated controllers and views give you a starting point that you can customize.

- Password authentication with optional resets, lockouts, and password history.
- Credential verification, magic-link integration, MFA, and recovery codes.
- OAuth integration, invitations, and impersonation.
- Explicit authentication scopes, customizable controllers, and lifecycle hooks.

## Requirements

- Ruby 3.2 or newer, subject to your Rails version's Ruby requirements.
- Rails 8.x.
- PostgreSQL is the tested database. Scalar primary keys, including UUIDs and renamed keys, are supported; composite keys are not.

Warden, BCrypt, `active_hooks`, and `otp_courier` are installed as dependencies. OAuth provider gems and TOTP libraries are optional; see the relevant feature guide before adding them.

## Installation and quick start

This example adds email/password authentication to an application using a single `User` model and the `:user` authentication scope. The scope generator creates new models and migrations; for an existing authentication schema, review [advanced setup](docs/setup.md) before running it.

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

The installer creates configuration and locale files and adds a `Vouch.routes(self)` block to `config/routes.rb`. The scope generator also creates that block if it is missing, so no manual route setup is needed for a standard Rails routes file.

### Generate authentication

```sh
bin/rails generate vouch:scope users User --single-model
```

This creates the `User` model, its migration, session and registration controllers, and basic accessible views. It also adds the authentication scope to `config/routes.rb`:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

This is generated for you. Re-running route generation does not add a duplicate scope. For an unusual or ambiguous routes file, the generator leaves it unchanged and prints the required route code.

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

The verification task checks configured models, associations, and feature requirements without changing the database. Your application supplies any additional password rules, account validations, and UI styling.

### Try it

Ensure your application has a `root` route: Vouch redirects there after sign-up and sign-in. The next section includes a protected home page example.

Start your Rails server and open `/users/sign_up` to create an account, or `/users/sign_in` to sign in. Password reset and other optional routes are added separately.

## Basic usage

### Protect a page

Keep your normal controller superclass and add the authentication filter:

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

Unauthenticated visitors are redirected to sign-in, with GET destinations saved for their return. Helpers are added to Rails controllers automatically; pages remain public unless you add an authentication filter.

### Access the signed-in user

Each authentication scope supplies helpers to controllers and views:

| Helper | Value |
| --- | --- |
| `current_user` | The signed-in application identity. |
| `current_user_account` | The account that owns its credentials. |
| `user_signed_in?` | Whether this scope has completed authentication. |

In this single-model example, `current_user` and `current_user_account` return the same `User`. In a split-model scope, they return the membership and account respectively. A pending MFA or identity-selection flow does not count as signed in. An `:admin` scope supplies `authenticate_admin!`, `current_admin`, `current_admin_account`, and `admin_signed_in?`. See [controller integration](docs/controllers.md) for filters, overrides, and Vouch’s own authentication controllers.

## Accounts, identities, and tenants

A single model is enough when each account has one application identity. For applications where one login can access several memberships, Vouch separates three roles:

| Role | Example | Purpose |
| --- | --- | --- |
| Account | `Account` | Owns the password and other credentials. |
| Identity | `User` | Represents an application membership. |
| Tenant (optional) | `Organisation` | Groups memberships within an organisation. |

For example, one `Account` can have a `User` membership in each of two organisations. Authentication verifies the account, then lets the person select an eligible identity when necessary.

For a new application using this structure, use this generator **instead of** the single-model command:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
```

The scope name can be omitted in hand-written routes; Vouch infers `:user` from `identity: "User"`. Select identity selection explicitly:

```ruby
Vouch.routes(self) do |auth|
  auth.scope account: "Account", identity: "User", tenant: "Organisation" do
    auth.sessions
    auth.registrations
    auth.user_selection
  end
end
```

For a single model, `auth.scope model: "User"` likewise infers `:user`. Namespaces are preserved: `Admin::User` infers `:admin_user`. Pass an explicit name, such as `auth.scope :operator, model: "User"`, to use the same model in a separate authentication scope. Scope names determine session separation and default routes; they do not grant roles or permissions.

Review the generated tenant fields and registration behavior for your application's schema. See [setup](docs/setup.md) and [model mapping](docs/model-mapping.md) for namespaced models, custom associations, UUIDs, and additional scopes.

## Optional features

Enable only the features your application needs. Each guide describes its generators, model requirements, routes, and extension points.

| Feature | Vouch provides | Your application supplies |
| --- | --- | --- |
| [Password reset and history](docs/passwords-and-recovery.md) | Reset tokens, password history, and optional reset UI generation. | Delivery, password rules, and feature configuration. |
| [Lockouts and authentication policy](docs/authentication-policy.md) | Account lock checks and a shared sign-in completion policy. | Access rules and session-revocation policy. |
| [Verification and magic links](docs/verification-and-mfa.md) | Credential proof issuance and verification APIs. | Delivery, controllers, routes, UI, and request limits. |
| [Multi-factor authentication](docs/verification-and-mfa.md) | Pending sign-in, factor challenges, and optional challenge UI generation. | Credential adapters, enrollment, delivery, and account preference controls. |
| [Recovery and backup codes](docs/passwords-and-recovery.md) | Code generation, hashed storage, and single-use consumption. | Code presentation and recovery UI. |
| [OAuth](docs/oauth.md) | Account-owned OAuth identities and callback controllers. | Provider configuration, routes, and registration/linking policy. |
| [Invitations](docs/invitations.md) | Invitation lifecycle and a generated controller and form. | Authorization, delivery, and account/membership creation rules. |
| [Impersonation](docs/impersonation.md) | Identity switching and restoration of the original operator. | Authorization and application UI. |

Invitation and impersonation authorization deny access until you implement the corresponding policy. MFA enrollment and magic-link flows require application integration; enabling a model concern alone does not supply a complete user interface.

## Customization and reference

Vouch handles authentication mechanics. Your application owns its schema, validation, authorization, delivery, and presentation. Generated files live in your application and can be edited.

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

Configure PostgreSQL access for the dummy application in `spec/dummy/config/database.yml` or through your local PostgreSQL environment. Compatibility CI runs the suite against Rails 8.0 and 8.1. Tests cover requests, sessions, generators, model contracts, concurrency, and generated application integration; this does not certify live OAuth providers, alternative databases, or browser presentation.

## Contributing

[Bug reports and pull requests](https://github.com/NicolasJJensen/rails_vouch) are welcome. Include reproduction steps and your Ruby, Rails, and database versions when reporting an issue.

## License

Vouch is available under the [MIT License](LICENSE.txt).
