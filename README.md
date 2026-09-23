# Vouch

Vouch adds password authentication, registration, password resets, MFA, OAuth, invitations, and impersonation to Rails applications. It generates controllers and views you can customize and works with your application's models.

## Install

Requires Rails 8.x and Ruby 3.2 or newer, subject to your Rails version's requirements.

```sh
bundle add rails_vouch
bin/rails generate vouch:install
bin/rails generate vouch:scope users User --single-model
bin/rails db:migrate
```

The generator creates a `User` model with password authentication, normalized email addresses, and email validation. It also creates sign-in and registration controllers, forms, and routes:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

## Protect pages

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

`authenticate_user!` redirects visitors to sign-in and returns them to the requested page afterward. `current_user` returns the signed-in `User`; `user_signed_in?` checks whether one is signed in.

Vouch adds these methods through `Vouch::ApplicationHelpers`, which is included automatically in Rails controllers. `current_user` and `user_signed_in?` are also available in views.

Keep authentication requirements in a base such as `AuthenticatedController`, because Vouch's public sign-in and registration endpoints also inherit `ApplicationController`.

## Sign-in and registration links

| Action | Route | Helper |
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

## Choose a destination after sign-in

Sign-in and registration default to your application's `root_path`. Override the destination in the generated controller:

```ruby
class Users::SessionsController < Vouch::SessionsController
  private

  def after_sign_in_path
    projects_path
  end
end
```

A previously requested protected page takes precedence over this fallback. See [controllers](docs/controllers.md#redirects) for registration, sign-out, and shared redirect methods that also cover MFA and OAuth completion.

## Add authentication features

- [Password resets and password history](docs/passwords-and-recovery.md)
- [Phone verification and MFA](docs/verification-and-mfa.md)
- [Sign in with an OAuth provider](docs/oauth.md)
- [Invite people to your application](docs/invitations.md)
- [Impersonate a user for support](docs/impersonation.md)

[Setup and customization](docs/setup.md) also covers usernames, multiple login resolvers, and custom models.

## Multi-tenant applications

For people who can belong to several organisations, separate their credentials from their memberships:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
bin/rails db:migrate
```

`Account` holds the email and password. Each `User` belongs to that account and one `Organisation`. The generated registration form creates an account, an organisation, and its initial membership.

The routes have one scope for account sign-in and another for selecting a membership:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :account, model: "Account" do
    auth.sessions
    auth.registrations
  end

  auth.scope :user, account_scope: :account, identity: "User", tenant: "Organisation" do
    auth.sessions
  end
end
```

Continue using `before_action :authenticate_user!` on organisation pages. It checks both the account and its selected membership:

1. A visitor signs in to their account, completing MFA if enabled.
2. One available membership is selected automatically; several produce a selection form.
3. The visitor returns to the page they requested. An account without an available membership cannot enter organisation pages.

Use `current_account` for credentials, `current_user` for the selected membership, and `current_organisation` for its organisation. Tenant helper names follow your tenant model's name.

An account-only page, such as a membership chooser, can use `authenticate_account!`. Signing out of the account ends its membership sessions; signing out of a membership leaves the account signed in.

See [model mapping](docs/model-mapping.md) for associations, primary keys, and separate administrator logins.

## Further customization

- [Controllers and complete route reference](docs/controllers.md)
- [Authentication policies](docs/authentication-policy.md)
- [Sessions and lifecycle hooks](docs/sessions-and-hooks.md)
- [Handling cancelled changes](docs/persistence.md)
- [Integrating with an existing Warden configuration](docs/warden.md)
- [Testing custom MFA credentials](docs/credential-adapter-contract.md)

## Development

```sh
bundle install
RAILS_ENV=test bundle exec rake app:db:prepare
bundle exec rspec
```

The test suite uses PostgreSQL. The development Gemfile uses sibling `active_hooks` and `otp_courier` checkouts; use `VOUCH_RELEASE_DEPS=1` to install published dependencies instead.

[Changelog](CHANGELOG.md) · [MIT license](LICENSE.txt)
