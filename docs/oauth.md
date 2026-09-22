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

For split models, always generate against the account, not the membership. OAuth creation and linking use `Account#oauth_identities`; they do not create or select an `Organisation`. Keep tenant selection and membership creation in registration policy.

## Routes and provider middleware

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, account: "Account", identity: "User", tenant: "Organisation",
    associations: {account_identities: :users, identity_account: :account,
      identity_tenant: :organisation, tenant_identities: :users,
      omniauthable: :oauth_identities} do
    auth.sessions
    auth.registrations
    auth.user_selection
    auth.oauth_callbacks
  end
end
```

The generator intentionally does not add a provider, controller, or route because those are host policy. Define the callback controller when needed:

```ruby
class Users::OmniAuthsController < Vouch::OmniAuthsController
  auth_scope :user
end
```

Default callback paths are `/users/auth/:provider/callback` and `/users/auth/failure`, with the corresponding `/admins/...` paths for an admin scope. Configure OmniAuth middleware paths and provider redirect allowlists to match. Route generation does not configure credentials or disable state validation; callbacks must come through configured provider middleware. Use `callback_path:`, `failure_path:`, and only methods required by the provider, for example `callback_methods: [:get, :post]`.

For example:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, account: "Account", identity: "User" do
    auth.sessions
    auth.oauth_callbacks callback_methods: [:get, :post]
  end
end
```

An already signed-in identity links a provider to its own account and cannot link a provider owned by another account.

## Deferred registration

By default, an unknown callback immediately creates the account, OAuth identity, and application identity. Override protected `oauth_registration_required?` to require the ordinary sign-up form. Vouch stores a protected continuation for `pending_authentication_ttl` and redirects to sign-up. The form calls `new_from_omniauth`; its POST merges only permitted account fields and atomically creates the account, OAuth identity, and registration identity or tenant. Provider and UID always come from protected session state, never request parameters. Invalid, expired, or malformed context is cleared.

Continuation retains provider, UID, and default profile fields email, name, and image. It never retains provider access or refresh tokens. Cookie-session hosts with stricter size limits should override protected `serialize_oauth` and `parse_oauth` together with a bounded serializable representation. The original AuthHash is available during immediate completion and `oauth_account_creation`; later hooks receive the reconstructed payload. Existing-account profile updates run inside the final `oauth_sign_in` transaction and wait for MFA and selection. A before-hook abort skips the update; rollback reverses it.
