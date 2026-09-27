# Models and authentication scopes

In a multi-tenant application, one `Account` signs in and selects a `User` membership in an `Organisation`. Nest the membership declaration inside its account scope:

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

Scope names are inferred from the model names. `current_account` returns the signed-in account, `current_user` its selected membership, and `current_organisation` the selected organisation.

## Contents

- [One model](#one-model)
- [Multi-tenant models](#multi-tenant-models)
- [Shared account scopes](#shared-account-scopes)
- [Exclude inactive memberships](#exclude-inactive-memberships)
- [Change route names](#change-route-names)
- [Primary keys](#primary-keys)
- [Custom association names](#custom-association-names)
- [Separate administrator logins](#separate-administrator-logins)

## One model

A single `User` model can hold passwords and represent the signed-in person:

```ruby
auth.scope model: "User" do
  auth.sessions
  auth.registrations
end
```

This configuration gives you `current_user`, `user_signed_in?`, and `authenticate_user!`.

## Multi-tenant models

The command in the [README](../README.md#use-a-shared-account-and-memberships) creates these relationships:

```ruby
class Account < ApplicationRecord
  has_many :users, dependent: :destroy
end

class User < ApplicationRecord
  belongs_to :account
  belongs_to :organisation
end

class Organisation < ApplicationRecord
  has_many :users, dependent: :destroy
end
```

The generated `Account` also includes Vouch authentication, `has_secure_password`, and email normalization and validation. The migrations create:

```ruby
create_table :accounts do |t|
  t.string :email_address, null: false
  t.string :password_digest, null: false
  t.bigint :auth_session_version, null: false, default: 0
  t.timestamps
  t.index "lower(email_address)", unique: true, name: "index_accounts_on_lower_email_address"
end

create_table :organisations do |t|
  t.string :name, null: false
  t.timestamps
end

create_table :users do |t|
  t.references :account, null: false, foreign_key: true
  t.references :organisation, null: false, foreign_key: true
  t.timestamps
end
```

After account authentication and any required MFA, Vouch checks the account's memberships. With one eligible membership it continues automatically; with several it shows a selector; with none it denies membership access. An organisation may require an additional [MFA challenge](authentication-policy.md#mfa-required-by-an-organisation).

`authenticate_user!` requires both account authentication and a selected membership. Use `authenticate_account!` for settings available before an organisation is selected.

## Shared account scopes

The [standard nested setup](../README.md#use-a-shared-account-and-memberships) generates an `Account` with `User` memberships in organisations. A separately declared membership can reference an existing account scope with `account_scope:`. This is equivalent to nesting; it can be useful when routes are organized in separate files:

```ruby
Vouch.routes(self) do |auth|
  auth.scope model: "Account" do
    auth.sessions
    auth.registrations
  end

  auth.scope :user, account_scope: :account, identity: "User", tenant: "Organisation" do
    auth.sessions
  end
end
```

`account_scope: :account` connects membership selection to the existing account login. Omitting `tenant:` also supports separate account and identity models without organisation ownership. Do not add it to the normal nested declaration above.

`authenticate_user!` checks both sessions. `current_account.users` lists all memberships; `current_user` is the selected one. `current_organisation` is that membership's organisation.

## Exclude inactive memberships

For example, if your `User` model has an `active` boolean, exclude inactive memberships from both automatic selection and the chooser:

```ruby
class Users::SessionsController < Vouch::MembershipSessionsController
  private

  def candidate_identities_for(account)
    super.where(active: true)
  end
end
```

Starting from `super` keeps the lookup restricted to the signed-in account. Vouch checks the permitted choices again when the selection is submitted.

## Change route names

```ruby
auth.scope model: "User", path: "members", as: "member" do
  auth.sessions
end
```

| Setting | Result |
| --- | --- |
| `path: "members"` | `/members/sign_in` |
| `as: "member"` | `new_member_session_path` |
| Scope remains `:user` | `current_user` and `authenticate_user!` |

Without an explicit scope name, `User` infers `:user`; `Staff::User` infers `:staff_user`.

## Primary keys

Declare custom primary keys using Rails:

```ruby
class User < ApplicationRecord
  self.primary_key = "user_number"
end
```

The key can be an integer, UUID, or string. For a composite key:

```ruby
class User < ApplicationRecord
  self.primary_key = [:organisation_id, :user_number]
end
```

A membership is then identified by both values. Associations and database foreign keys referencing it must include both columns. Vouch carries the complete key through sign-in, MFA, invitations, and session restoration.

Ordinary scalar IDs, including UUIDs and renamed keys, work with normal Rails route helpers:

```erb
<%= button_to "View as this user", user_impersonate_path(user), method: :post %>
```

For composite keys, use Vouch's route encoding in custom links and forms:

```erb
<%= button_to "View as this user", user_impersonate_path(Vouch::RecordKey.to_param(user)), method: :post %>
```

`Vouch::RecordKey.to_param` encodes every component, preserving its type. The receiving Vouch controller decodes that value and looks up the complete key. Generated forms already handle this.

## Custom association names

If your models call their relationships `owner` and `workspace`, tell Vouch which associations to use:

```ruby
auth.scope :user, account_scope: :account, identity: "User", tenant: "Organisation", associations: {
  account_identities: :memberships,
  identity_account: :owner,
  tenant_identities: :memberships,
  identity_tenant: :workspace
} do
  auth.sessions
end
```

Vouch otherwise discovers relationships by their target model. Explicit names are useful when several associations point to the same class. Core account/membership/tenant relationships currently require concrete target models; polymorphic relationships are not supported there.

## Separate administrator logins

This is optional. Many applications use one user model with their own role and permission rules.

For separate administrator credentials:

```ruby
auth.scope model: "Admin" do
  auth.sessions
end
```

Use `authenticate_admin!` on administrator pages.

If administrators instead share an `Account` password with ordinary memberships, add an `Admin` membership model belonging to `Account` and `Organisation`, with matching `has_many :admins` associations:

```ruby
auth.scope :admin, account_scope: :account, identity: "Admin", tenant: "Organisation" do
  auth.sessions
end
```

The person has one password and MFA setup, but separate selected user and administrator memberships. Locking that account prevents both forms of access.

`current_account_user` and `current_account_admin` are also available as `current_user` and `current_admin`. When both scopes use `Organisation`, use `current_user_organisation` and `current_admin_organisation`; an ambiguous `current_organisation` alias is not generated.
