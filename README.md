# Vouch

Vouch adds authentication to Rails: password sign-in, registration, password resets, MFA, recovery codes, OAuth, invitations and impersonation. It generates controllers and views in your application so you can customize each flow.

## Install

Requires Rails 8.x and Ruby 3.2 or newer, subject to your Rails version’s requirements.

```sh
bundle add rails_vouch
bin/rails generate vouch:install
bin/rails generate vouch:scope User
bin/rails db:migrate
```

The scope generator creates `User`, sign-in and registration controllers, forms, and routes. The generated model normalizes and validates `email_address` and uses `has_secure_password`.

For a new `User`, the migration creates:

```ruby
create_table :users do |t|
  t.string :email_address, null: false
  t.string :password_digest, null: false
  t.bigint :auth_session_version, null: false, default: 0
  t.timestamps
end
add_index :users, "lower(email_address)", unique: true, name: "index_users_on_lower_email_address"
```

The generated routes select the features available for this login:

```ruby
Vouch.routes(self) do |auth|
  auth.scope model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

## Protect pages

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

`authenticate_user!` sends visitors to sign-in and returns them to the requested page afterward. `current_user` returns the signed-in user; `user_signed_in?` checks whether one is signed in.

These methods come from `Vouch::ApplicationHelpers`, which Vouch automatically includes in Rails controllers. Current-record and signed-in helpers are available in views too.

Keep forced authentication in `AuthenticatedController`: the generated sign-in and registration endpoints inherit your `ApplicationController` and must be accessible before sign-in.

## Sign-in links

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

## Redirect after sign-in

Sign-in returns to the requested protected page, or `root_path` if there was no requested page. Change that fallback in the generated controller:

```ruby
# app/controllers/users/sessions_controller.rb
class Users::SessionsController < Vouch::SessionsController
  private

  def after_sign_in_path
    projects_path
  end
end
```

[Controllers and redirects](docs/controllers.md#redirects) also covers registration, sign-out and shared redirects that apply when MFA or OAuth completes sign-in.

## Add a feature

- [Password reset and password history](docs/passwords-and-recovery.md)
- [Verification, MFA and recovery codes](docs/verification-and-mfa.md)
- [OAuth sign-in](docs/oauth.md)
- [Invitations](docs/invitations.md)
- [Impersonation for support access](docs/impersonation.md)

Each guide shows its generator, schema changes, generated pages and customization methods.

## Multi-tenant applications

When one person can join several organisations, separate the account from its memberships:

```sh
bin/rails generate vouch:scope User --account Account --tenant Organisation
bin/rails db:migrate
```

`Account` holds the email and password. Each `User` belongs to that account and an `Organisation`. The registration form asks for an organisation name and creates the account, organisation and first membership together.

The migrations create `accounts` with the credential columns shown above, `organisations` with a required `name`, and `users` with required foreign keys:

```ruby
create_table :organisations do |t|
  t.string :name, null: false
  t.timestamps
end
create_table :accounts do |t|
  t.string :email_address, null: false
  t.string :password_digest, null: false
  t.bigint :auth_session_version, null: false, default: 0
  t.timestamps
end
add_index :accounts, "lower(email_address)", unique: true, name: "index_accounts_on_lower_email_address"
create_table :users do |t|
  t.bigint :account_id, null: false
  t.bigint :organisation_id, null: false
  t.timestamps
end
add_index :users, :account_id
add_index :users, :organisation_id
add_foreign_key :users, :accounts
add_foreign_key :users, :organisations
```

Continue using `authenticate_user!` on organisation pages. It checks the account authentication and selected membership. One available membership is selected automatically; several produce a selection page. Required MFA must complete before access is granted.

Use `current_account`, `current_user` and `current_organisation` to access those records. An account settings page can use `authenticate_account!` without requiring an organisation membership.

[Setup](docs/setup.md#multi-tenant-setup) shows the generated models and routes. [Authentication policies](docs/authentication-policy.md) explains organisation-specific MFA requirements.

## Customize the implementation

Edit the generated views and controller subclasses for ordinary changes. When you need to edit an endpoint’s actions directly, [eject its controller](docs/controllers.md#eject-a-controller) into your application:

```sh
bin/rails generate vouch:eject users sessions
```

Further guides:

- [Setup, usernames and login resolvers](docs/setup.md)
- [Controllers, routes and ejection](docs/controllers.md)
- [Models, keys and authentication scopes](docs/model-mapping.md)
- [Authentication policies](docs/authentication-policy.md)
- [Sessions and lifecycle hooks](docs/sessions-and-hooks.md)
- [Advanced integration and persistence](docs/persistence.md)
- [Existing Warden middleware](docs/warden.md)
- [Testing a custom MFA credential](docs/credential-adapter-contract.md)

## Development

```sh
bundle install
RAILS_ENV=test bundle exec rake app:db:prepare
bundle exec rspec
```

The suite uses PostgreSQL. The development Gemfile uses sibling `active_hooks` and `otp_courier` checkouts; set `VOUCH_RELEASE_DEPS=1` to use published dependencies.

[Changelog](CHANGELOG.md) · [MIT license](LICENSE.txt)
