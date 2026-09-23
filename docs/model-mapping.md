# Accounts, memberships, and authentication scopes

An account owns credentials. A membership identifies how that account participates in an organisation. An authentication scope names one session context; a tenant identifies an organisation. Scope names do not grant application permissions.

## Single-tenant authentication

One model can own credentials and represent the authenticated person:

```ruby
auth.scope :user, model: "User" do
  auth.sessions
  auth.registrations
end
```

This exposes `current_user`, `user_signed_in?`, and `authenticate_user!`. There is no redundant account helper. A `model:` mapping cannot also declare `tenant:`.

## Multi-tenant authentication

A common database arrangement is:

```text
accounts:      id, email_address, password_digest
organisations: id, name
users:         id, account_id, organisation_id
```

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password
  has_many :users
end

class User < ApplicationRecord
  belongs_to :account
  belongs_to :organisation
end

class Organisation < ApplicationRecord
  has_many :users
end
```

The account holds authentication features; the user is a membership. Existing model validations and other associations are omitted from this example.

```ruby
auth.scope :account, model: "Account" do
  auth.sessions
  auth.registrations
end

auth.scope :user, account_scope: :account,
  identity: "User", tenant: "Organisation" do
  auth.sessions
end
```

Declare the account scope before its membership scopes. `account_scope:` references a single-model credentials scope and derives the account class from it. Omit `tenant:` when separating credentials from identities without tenant ownership.

The generated account email is unique. Email/password lookup identifies one account; membership selection then considers that account's eligible identities. Zero denies membership access, one selects automatically, and several require a choice. Required MFA completes before the account session is established. A direct account login does not guess a membership scope; a membership guard or link starts that continuation.

The generator does not assume that one account can have only one membership per organisation. If that is your rule, add a unique composite index on `[:account_id, :organisation_id]` and matching model validation.

## Shared account, separate user and admin memberships

Add an `admins` table with `account_id` and `organisation_id`, an `Admin` model with both `belongs_to` associations, and `has_many :admins` on `Account` and `Organisation`:

```ruby
auth.scope :admin, account_scope: :account,
  identity: "Admin", tenant: "Organisation" do
  auth.sessions
end
```

The sessions are independent selections beneath one account:

```ruby
current_account
current_account_user  # alias: current_user
current_account_admin # alias: current_admin
```

A user membership never satisfies `authenticate_admin!`. The membership controller's `candidate_identities_for(account)` can further restrict eligible records. The application still authorizes actions within the selected membership.

Passwords, account lockout, and account-level MFA policy are shared because the credentials record is shared. Signing out of the account clears both membership sessions. Ending one membership session leaves the account and the other membership authenticated. User and admin memberships may belong to different organisations, so use `current_user.organisation` or `current_admin.organisation` explicitly.

For separate administrator credentials, create another single-model account scope and reference it instead:

```ruby
auth.scope :admin_account, model: "AdminAccount" do
  auth.sessions
end

auth.scope :admin, account_scope: :admin_account,
  identity: "Admin", tenant: "Organisation" do
  auth.sessions
end
```

Here `Admin` belongs to `AdminAccount`. Platform-wide administrators can omit tenant mapping.

## Names and helper generation

When omitted, the scope name comes from `model:` or `identity:`: `User` becomes `:user`, and `Admin::Account` becomes `:admin_account`. Explicit names let the same model serve different authentication contexts.

`Vouch::ApplicationHelpers` constructs helper methods from scope names when mappings are registered. A membership's qualified helper includes its parent scope, such as `current_account_user`; `current_user` is its short scope helper. Conflicting generated names raise an error during configuration rather than choosing a session at runtime.

`path:` changes URL prefixes and `as:` changes route-helper prefixes. Neither changes the Warden scope or current-record helper names.

## Custom associations and polymorphism

Vouch resolves concrete Active Record relationships by their target classes. Specify association names if several relationships match:

```ruby
auth.scope :user, account_scope: :account,
  identity: "User", tenant: "Organisation",
  associations: {
    account_identities: :memberships,
    identity_account: :owner,
    tenant_identities: :memberships,
    identity_tenant: :workspace
  } do
  auth.sessions
end
```

The named associations must still point to the mapped classes. Account/membership and tenant/membership relationships cannot be polymorphic; an explicit association name does not bypass that restriction. Composite primary keys are unsupported.

OAuth ownership is a supported exception. An OAuth identity can belong polymorphically to its credentials owner; see [OAuth](oauth.md). Feature associations are resolved only for installed features.

## Password history and verification

Password-history association selection belongs on the credentials model:

```ruby
class Account < ApplicationRecord
  has_many :password_archives
  authenticates_with :password_trackable,
    password_trackable: { association: :password_archives }
end
```

Lock and reload the account before concurrent password writes so history uses the current digest. Every scope using the account shares that association selection.

Run `bin/rails vouch:verify` after changing mappings. It validates loaded model and feature contracts without modifying the schema.
