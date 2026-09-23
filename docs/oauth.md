# OAuth

OAuth identities belong to the authentication account, not to application memberships. This guide extends the [README](../README.md); see [controllers](controllers.md) for route customization and [authentication policy](authentication-policy.md) for MFA policy.

## Installation and ownership

Install OmniAuth and the provider strategy, then generate an account-owned identity:

```sh
bundle add omniauth omniauth-github
bin/rails g vouch:omniauth accounts
bin/rails db:migrate
```

`accounts` is the default generator argument; `Account` is also accepted. The generator creates `OauthIdentity` with `account_id` and the owner association. For a single-model scope, target that model instead; the identity belongs to `Member`.

The ordinary split-model owner wiring is:

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :omniauthable

  has_many :oauth_identities, class_name: "OauthIdentity",
    foreign_key: :account_id, dependent: :destroy
end
```

For a single-model scope, target that model, add `authenticates_with :omniauthable` to `Member`, and enable its generated association and callback route:

```sh
bin/rails g vouch:scope members Member --single-model
bin/rails g vouch:omniauth members
bin/rails db:migrate
```

```ruby
Vouch.routes(self) do |auth|
  auth.scope :member, model: "Member", associations: {omniauthable: :oauth_identities} do
    auth.sessions
    auth.registrations
    auth.oauth_callbacks
  end
end

class Members::OmniAuthsController < Vouch::OmniAuthsController
  auth_scope :member
end
```

For split models, always generate against the account, not the membership. OAuth creation and linking use `Account#oauth_identities`; membership and tenant provisioning belongs in the application's `build_registration` override. Keep that override shared between registration and OAuth controllers when both should provision the same records.

## Routes and provider middleware

```ruby
Vouch.routes(self) do |auth|
  auth.scope :account, model: "Account",
    associations: {omniauthable: :oauth_identities} do
    auth.sessions
    auth.registrations
    auth.oauth_callbacks
  end
end
```

The generator intentionally does not add a provider, controller, or route because those are host policy. Define the callback controller when needed:

```ruby
class Accounts::OmniAuthsController < Vouch::OmniAuthsController
  auth_scope :account
end
```

Default callback paths are `/accounts/auth/:provider/callback` and `/accounts/auth/failure`, with the corresponding paths for other credentials scopes. Configure OmniAuth middleware paths and provider redirect allowlists to match. Route generation does not configure credentials or disable state validation; callbacks must come through configured provider middleware. Use `callback_path:`, `failure_path:`, and only methods required by the provider, for example `callback_methods: [:get, :post]`.

For example:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :account, model: "Account" do
    auth.sessions
    auth.oauth_callbacks callback_methods: [:get, :post]
  end
end
```

An already signed-in identity links a provider to its own account and cannot link a provider owned by another account.

## Configure a provider

For the account routes above, configure OmniAuth to use the same path prefix:

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    Rails.application.credentials.dig(:github, :client_id),
    Rails.application.credentials.dig(:github, :client_secret),
    path_prefix: "/accounts/auth"
end
```

Configure `/accounts/auth/github/callback` with the provider. Install `omniauth-rails_csrf_protection` for Rails request-phase CSRF protection and use a POST button to begin:

```erb
<%= button_to "Sign in with GitHub", "/accounts/auth/github", data: { turbo: false } %>
```

Successful OAuth establishes the account session. A requested membership continuation then selects the relevant membership; direct account OAuth login uses its account redirect.

## Polymorphic OAuth ownership

The generated OAuth owner is concrete. Applications that need shared OAuth storage can instead configure a polymorphic owner:

```ruby
class OauthIdentity < ApplicationRecord
  include Vouch::OAuthIdentity::Concern
  belongs_to :account, polymorphic: true
end

class Account < ApplicationRecord
  has_many :oauth_identities, as: :account
end
```

Supply the corresponding `account_type` and `account_id` schema. When needed, select the association with `associations: { omniauthable: :oauth_identities, oauth_account: :account }` on the credentials mapping. This support does not extend to polymorphic core account/membership/tenant relationships.

## Deferred registration

By default, an unknown callback creates the account and OAuth identity and calls `build_registration`. The generated account registration controller provisions initial memberships for password signup; share that provisioning override with the OAuth controller if OAuth signup must create the same memberships. Override protected `oauth_registration_required?` to require the ordinary sign-up form. Vouch stores a protected continuation for `pending_authentication_ttl` and redirects to sign-up. The form calls `new_from_omniauth`; its POST merges only permitted account fields and atomically creates the account, OAuth identity, and registration identity or tenant. Provider and UID always come from protected session state, never request parameters. Invalid, expired, or malformed context is cleared.

Continuation retains provider, UID, and default profile fields email, name, and image. It never retains provider access or refresh tokens. Cookie-session hosts with stricter size limits should override protected `serialize_oauth` and `parse_oauth` together with a bounded serializable representation. The original AuthHash is available during immediate completion and `oauth_account_creation`; later hooks receive the reconstructed payload. Existing-account profile updates run inside the account `oauth_sign_in` transaction after any required MFA; linked membership selection follows account authentication. A before-hook abort skips the update; rollback reverses it.
