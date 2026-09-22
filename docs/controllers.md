# Controllers and routes

The baseline route setup is in the [README](../README.md). This guide covers controller inheritance, route selection, and customization. See [authentication policy](authentication-policy.md) for completion rules and [sessions and hooks](sessions-and-hooks.md) for lifecycle behavior.

## Application controllers

Vouch adds a small helper module to Rails controllers automatically. Keep inheriting from `ApplicationController` and require authentication only on the pages that need it:

```ruby
class DashboardController < ApplicationController
  before_action :authenticate_user!

  def show
    @membership = current_user
    @account = current_user_account
  end
end
```

Each registered scope defines `authenticate_<scope>!`, `current_<scope>`, `current_<scope>_account`, and `<scope>_signed_in?`. The last three are available in views. For `:admin_user`, for example, use `authenticate_admin_user!` and `current_admin_user`. The account accessor derives the account from the completed identity; pending MFA or identity selection never counts as authenticated. With one model, the identity and account are the same record.

The filter redirects to that scope's sign-in route and preserves GET destinations. Helpers follow current mappings and custom route helper prefixes. They do not add a global authentication filter or registration/completion internals to your application controllers. Existing methods defined by your application can override these helpers.

## Authentication controllers

Auth controllers inherit `Vouch::BaseController`, which supplies scope-aware guards. The configured parent defaults to `ApplicationController`:

```ruby
Vouch.configure do |config|
  config.parent_controller = "ApplicationController"
  config.authentication_callbacks = [:authenticate_user!]
end
```

Declare `authentication_callbacks` only when the parent already installs authentication filters. Public auth actions skip those filters; protected actions retain them. Configure the parent before loading auth controllers. Vouch’s own auth controllers continue to use scope-aware `current_identity` and `current_account` internally, independently of application overrides to `current_user`. Keep feature controllers inheriting from their Vouch base class; ordinary application controllers do not need that superclass. Override redirects when the host does not use `root_path`.

Use `auth_scope` when namespace inference is unsuitable:

```ruby
class Members::PasswordsController < Vouch::PasswordsController
  auth_scope :member
end

Vouch.routes(self) do |auth|
  auth.scope :member, model: "Member" do
    auth.sessions
    auth.registrations
    auth.passwords controller: "members/passwords"
  end
end
```

Every scope requires a block. Select baseline session, registration, and split-model identity-selection routes explicitly. Add optional methods only after installing the feature concern, migration, association, controller/view support, and delivery hook. Optional routes map to these controllers:

| Route | Controllers | Base controller |
| --- | --- | --- |
| `auth.passwords` | `PasswordsController` | `Vouch::PasswordsController` |
| `auth.two_factor` | `TwoFactorChallengeController`, `TwoFactorCredentialsController` | matching Vouch controllers |
| `auth.oauth_callbacks` | `OmniAuthsController` | `Vouch::OmniAuthsController` |

Registration exposes `registration_tenant_attributes`, `registration_identity_attributes`, and `build_registration`. Tenant scopes must provide tenant attributes. Custom identity-to-account associations use `associations: {identity_account: :owner}`.

## Endpoints and host UI

After installation, check `GET /users/sign_in` and `GET /users/sign_up`. `GET /users/password/new` exists only when password routes are enabled. Generated views are accessible starting points; replace them with host UI and validations. Feature-specific enrollment views, authorization, delivery, and permitted fields remain host-owned.

## Hooks for OAuth controllers

OAuth continuation customization belongs on the concrete OAuth controller or a host controller superclass inheriting `Vouch::BaseController`: override protected `serialize_oauth` and `parse_oauth` together. The configured parent is an ancestor of `Vouch::BaseController` and cannot override these included helpers. Authentication completion and session continuation helpers are internal wiring.

## Ejecting a controller

Use a subclass for a small override. To copy a shipped controller into your application for broader customization:

```sh
bin/rails g vouch:eject users sessions
```

The generated controller keeps Vouch's runtime `auth_mapping` helpers. When its namespace differs from the authentication scope, pass `--auth-scope`, for example `bin/rails g vouch:eject portal sessions --auth-scope user`. The deprecated `--concrete` option is an alias for the same output; it no longer inlines mapping classes or associations.
