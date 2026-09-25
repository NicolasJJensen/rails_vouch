# Models and authentication scopes

## One model

A single `User` model can hold passwords and represent the signed-in person:

```ruby
auth.scope :user, model: "User" do
  auth.sessions
  auth.registrations
end
```

This configuration gives you `current_user`, `user_signed_in?`, and `authenticate_user!`.

## Shared account scopes

The [multi-tenant setup](setup.md#multi-tenant-setup) generates an `Account` with `User` memberships in organisations. Use separate declarations when more than one membership scope needs the same account login:

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

`account_scope: :account` connects membership selection to the existing account login. Omitting `tenant:` also supports separate account and identity models without organisation ownership.

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
auth.scope :user, model: "User", path: "members", as: "member" do
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
auth.scope :admin, model: "Admin" do
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
