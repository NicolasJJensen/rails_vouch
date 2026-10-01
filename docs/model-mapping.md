# Models and authentication scopes

An authentication scope names an independent sign-in session and connects it to your application models. Start with one model; add separate credentials and memberships when your application needs them.

## Contents

- [One model](#one-model)
- [Existing models](#existing-models)
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
# config/routes.rb, inside Rails.application.routes.draw
Vouch.routes(self) do |auth|
  auth.scope model: "User" do
    auth.sessions
    auth.registrations
  end
end
```

This configuration gives you `current_user`, `user_signed_in?`, and `authenticate_user!`.

## Existing models

The scope generator preserves existing model files. Before adding routes for an existing `User`, give it authentication support:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password
  normalizes :email_address, with: ->(value) { value.strip.downcase }
  validates :email_address, presence: true, uniqueness: true
end
```

Its table needs the credential columns shown in the [README schema](../README.md#install-and-generate-a-login): a uniquely indexed `citext` email, `password_digest`, and `auth_session_version`. The generator can add the session-version column when missing; it does not convert an existing table's email or password columns. Keep your existing model validations and add missing schema explicitly. For accounts without passwords, see [optional password validation](registration.md#accounts-without-passwords).

With separate models, also define their `belongs_to` relationships and database foreign keys before using the mapping. The examples below show those relationships for fresh models.

## Multi-tenant models

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

For new models, generate this setup with:

```sh
bin/rails generate vouch:scope User --account Account --tenant Organisation
bin/rails db:migrate
```

This adds credential and membership models, their migrations, account sign-in and registration endpoints, membership selection, views and the nested routes above. The models have these relationships:

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  has_many :users, dependent: :destroy
end

# app/models/user.rb
class User < ApplicationRecord
  belongs_to :account
  belongs_to :organisation
end

# app/models/organisation.rb
class Organisation < ApplicationRecord
  has_many :users, dependent: :destroy
end
```

The generated `Account` also includes Vouch authentication, `has_secure_password`, and email normalization and validation. The migrations create:

```ruby
enable_extension "citext" unless extension_enabled?("citext")

create_table :accounts do |t|
  t.citext :email_address, null: false, index: { unique: true }
  t.string :password_digest
  t.bigint :auth_session_version, null: false, default: 0
  t.timestamps
end

create_table :organisations do |t|
  t.timestamps
end

create_table :users do |t|
  t.references :account, null: false, foreign_key: true
  t.references :organisation, null: false, foreign_key: true
  t.timestamps
end
```

Signing in directly through the account route establishes the account session. Visiting a protected membership page, or its sign-in route, then selects a membership:

- One eligible membership is selected automatically.
- Several memberships show the generated chooser.
- No eligible memberships means there is nothing to select. The default endpoint returns HTTP 403, while the account stays signed in and can use account-only pages.

Account authentication and required login MFA complete before selection. Workspace permissions, including any requirements based on [MFA evidence](authentication-policy.md#mfa-evidence-and-application-permissions), belong to your application.

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

`account_scope: :account` connects membership selection to the existing account login. Omitting `tenant:` also supports separate account and identity models without organisation ownership. The nested `auth.membership` declaration gets this parent from its enclosing account block; the separate form uses `account_scope:` to name that same parent.

`authenticate_user!` checks both sessions. `current_account.users` lists the account's memberships; `current_user` is the selected one. `current_organisation` is that membership's organisation. During membership-only impersonation, `current_user` can belong to a different account while `current_account` remains the operator's account; see [impersonation modes](impersonation.md).

## Exclude inactive memberships

For example, if your `User` model has an `active` boolean, exclude inactive memberships from both automatic selection and the chooser:

```ruby
# app/controllers/users/sessions_controller.rb
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
# config/routes.rb, inside Vouch.routes(self)
auth.scope model: "User", path: "members", as: "member" do
  auth.sessions
end
```

| Setting | Result |
| --- | --- |
| `path: "members"` | `/members/sign_in` |
| `as: "member"` | `new_member_session_path` |
| Default controller | `Users::SessionsController` |
| Scope remains `:user` | `current_user` and `authenticate_user!` |

`path:` changes the URL only. The controller namespace follows the authentication scope; use `controller: "portal/sessions"` to select another controller. `as:` changes route helpers independently.

Without an explicit scope name, `User` infers `:user`; `Staff::User` infers `:staff_user`.

## Primary keys

Declare custom primary keys using Rails, with matching database keys and foreign-key constraints:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  self.primary_key = "user_number"
end
```

Keys can use Rails scalar types, including integers, UUIDs, strings, dates, timestamps and decimals. For a composite key:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  self.primary_key = [:organisation_id, :user_number]
end
```

A membership is then identified by both values. Associations and database foreign keys referencing it must include both columns. Vouch carries the complete key through sign-in, MFA, invitations, and session restoration.

Generators read literal `self.table_name` and `self.primary_key` declarations and existing database column types without loading the model. Load a model before generation if those declarations are computed dynamically; Vouch reports an error instead of guessing. For a new, nonstandard scalar key without an existing table, supply the generator's `--primary-key-type` option.

The following links assume [impersonation routes](impersonation.md) are installed. Ordinary scalar IDs, including UUIDs and renamed keys, work with normal Rails route helpers:

```erb
<%= button_to "View as this user", user_impersonate_path(user), method: :post %>
```

For composite keys, use Vouch's route encoding in custom links and forms:

```erb
<%= button_to "View as this user", user_impersonate_path(Vouch::RecordKey.to_param(user)), method: :post %>
```

`Vouch::RecordKey.to_param` encodes every component, preserving its type, timestamp precision and decimal value. The receiving Vouch controller decodes that value and looks up the complete key. Generated forms already handle this.

## Custom association names

If your models call their relationships `owner` and `workspace`, define the Rails associations with the matching foreign keys:

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  has_many :memberships, class_name: "User", foreign_key: :owner_id
end

# app/models/user.rb
class User < ApplicationRecord
  belongs_to :owner, class_name: "Account"
  belongs_to :workspace, class_name: "Organisation"
end

# app/models/organisation.rb
class Organisation < ApplicationRecord
  has_many :memberships, class_name: "User", foreign_key: :workspace_id
end
```

Then map those existing associations. These options do not create associations or columns:

```ruby
# config/routes.rb, inside Vouch.routes(self)
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
# config/routes.rb, inside Vouch.routes(self)
auth.scope model: "Admin" do
  auth.sessions
end
```

Use `authenticate_admin!` on administrator pages.

If administrators instead share an `Account` password with ordinary memberships, add an `Admin` membership model belonging to `Account` and `Organisation`, with matching `has_many :admins` associations:

```ruby
# config/routes.rb, inside Vouch.routes(self)
auth.scope :admin, account_scope: :account, identity: "Admin", tenant: "Organisation" do
  auth.sessions
end
```

The person has one password and MFA setup, but separate selected user and administrator memberships. Locking that account prevents both forms of access.

`current_account_user` and `current_account_admin` are also available as `current_user` and `current_admin`. When both scopes use `Organisation`, use `current_user_organisation` and `current_admin_organisation`; an ambiguous `current_organisation` alias is not generated.
