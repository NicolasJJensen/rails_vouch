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

## Organisation memberships

Separate credentials from membership when one person can belong to several organisations:

```text
Account ── has many ── User ── belongs to ── Organisation
```

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
bin/rails db:migrate
```

`Account` holds the person's email and password. `User` represents one organisation membership. The generated relationships are:

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password
  has_many :users
end
```

```ruby
class User < ApplicationRecord
  belongs_to :account
  belongs_to :organisation
end
```

```ruby
class Organisation < ApplicationRecord
  has_many :users
end
```

The account and membership have separate sessions, so their routes are declared separately:

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

Declare the account first so the membership can reference it. Omit `tenant:` if you separate credentials and identities without an organisation relationship.

Use `authenticate_user!` to require both account authentication and a membership. After account sign-in:

| Available memberships | Result |
| --- | --- |
| One | Selected automatically |
| Several | The person chooses one |
| None | Organisation access is denied |

`current_account` returns the credentials record, `current_user` the selected membership, and `current_organisation` its organisation. `current_account.users` lists memberships; it does not identify the selected one.

A direct visit to `/accounts/sign_in` signs into the account. A protected organisation page starts membership selection as well. Signing out of the account ends its memberships; ending a membership leaves the account signed in.

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

Use the generated route/form helpers rather than concatenating composite IDs yourself. Custom authentication forms can use `Vouch::RecordKey.to_param(record)` for a record's submitted identifier.

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
