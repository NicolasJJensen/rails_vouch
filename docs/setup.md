# Setup and customization

For email/password sign-in with a `User` model:

```sh
bin/rails generate vouch:install
bin/rails generate vouch:scope User
bin/rails db:migrate
```

The generator creates:

- `app/models/user.rb`, with password authentication and normalized, unique email addresses.
- `app/controllers/users/sessions_controller.rb` and `registrations_controller.rb`.
- Sign-in and registration forms under `app/views/users`.
- A `User` route scope in `config/routes.rb`.
- A migration whose schema is:

```ruby
create_table :users do |t|
  t.string :email_address, null: false
  t.string :password_digest, null: false
  t.bigint :auth_session_version, default: 0, null: false
  t.timestamps
end
add_index :users, "lower(email_address)", unique: true, name: "index_users_on_lower_email_address"
```

Edit the generated controllers and forms in your application. See [controller customization](controllers.md) for redirects, hooks and copying complete actions with the eject generator.

## Use another model name

For an application that calls its users `Member`:

```sh
bin/rails generate vouch:scope Member
```

This gives you `current_member`, `member_signed_in?`, and `authenticate_member!`, with sign-in at `/members/sign_in`. The model name supplies the default authentication scope and controller namespace. The migration has the same columns as `users` above, on `members`.

## Multi-tenant setup

Use an account for the person's email/password and a membership for each organisation they can access:

```sh
bin/rails generate vouch:scope User --account Account --tenant Organisation
bin/rails db:migrate
```

The generator creates these relationships:

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

The `accounts` migration uses the email, password, session-version and timestamp columns from the single-tenant example. The other migrations create:

```ruby
create_table :organisations do |t|
  t.string :name, null: false
  t.timestamps
end
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

Account authentication and membership selection have separate sessions. A nested route declaration connects them:

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

You can also declare the scopes separately; [authentication scopes](model-mapping.md#shared-account-scopes) shows that form.

The generated registration page collects an email, password and organisation name. Account, organisation and membership creation happen in one transaction. [Registration customization](controllers.md#registration) shows how to add other records.

Use `authenticate_user!` on organisation pages: it requires the account and selected membership. Vouch selects the only available membership automatically or displays a chooser when several are available. Use `authenticate_account!` for account settings that do not require an organisation.

The helpers are `current_account`, `current_user` and `current_organisation`. Signing out of the account ends its membership sessions; signing out of a membership leaves the account signed in.

## Add features

Choose a feature guide for the generator command, generated migration and pages:

- [Password resets and history](passwords-and-recovery.md)
- [Verification, MFA and recovery codes](verification-and-mfa.md)
- [OAuth](oauth.md)
- [Invitations](invitations.md)

The feature generators infer the authentication scope from the configured model. When a model has multiple authentication scopes, select one explicitly:

```sh
bin/rails generate vouch:password_resetable User --auth-scope customer --controller-path portal
```

That command uses the password-reset schema shown in the linked guide, with controllers under `app/controllers/portal`. To generate the model feature and schema without its pages:

```sh
bin/rails generate vouch:password_resetable User --model-only
```

Its migration adds:

```ruby
add_column :users, :password_reset_token_digest, :string
add_column :users, :password_reset_sent_at, :datetime
add_index :users, :password_reset_token_digest, unique: true
```

## Use usernames for sign-in

Email addresses are the default. You can instead find users by another attribute. This example keeps email for password-reset delivery but uses a unique `username` to sign in.

Generate a column, then add a unique index in its migration:

```sh
bin/rails generate migration AddUsernameToUsers username:string
```

The generated migration adds the column; add the unique index to it:

```ruby
def change
  add_column :users, :username, :string
  add_index :users, :username, unique: true
end
```

In `app/models/user.rb`, add:

```ruby
normalizes :username, with: ->(value) { value.strip.downcase }
validates :username, presence: true, uniqueness: { case_sensitive: false }
```

A login resolver finds a user from submitted fields. Vouch checks the password after a resolver finds that user.

Create `lib/username_resolver.rb`:

```ruby
class UsernameResolver < Vouch::LoginResolver::Base
  def valid?(params)
    params[:username].present?
  end

  def resolve!(params, account_class)
    username = params[:username].to_s.strip.downcase
    account = account_class.find_by(username: username)
    account ? success!(account) : fail!
  end
end
```

Register it in `config/initializers/vouch.rb`:

```ruby
require_relative "../../lib/username_resolver"

Vouch.configure do |config|
  config.register_login_resolver UsernameResolver
  config.register_login_resolver Vouch::LoginResolver::EmailResolver
end
```

Edit the existing resolver registrations rather than appending a second copy. This explicitly loaded `lib` class is loaded at application boot.

Change the sign-in field in `app/views/users/sessions/new.html.erb`:

```erb
<%= text_field_tag :username, params[:username], autocomplete: "username", required: true %>
```

Add a username field to the generated registration form and permit it in `app/controllers/users/registrations_controller.rb`:

```ruby
class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def account_params
    params.require(:user).permit(:username, :email_address, :password, :password_confirmation)
  end
end
```

If you remove email entirely, remove its generated validation and normalization too. Replace email lookup and delivery in password-reset and invitation flows with the identifier and delivery channel you use.

## Combine login resolvers

The registration order determines lookup order:

| Resolver outcome | What Vouch does |
| --- | --- |
| `valid?` returns false | Skips this resolver |
| `fail!` | Tries the next resolver |
| `success!(account)` | Stops lookup and checks this account's password |
| No resolver succeeds | Rejects sign-in |

A wrong password does not cause Vouch to try a different account. In the username/email example, a form with only `username` uses the username resolver; a password-reset form with `email_address` uses the email resolver.

## Custom tables and primary keys

Vouch uses the primary key declared by your model, including custom names and composite keys. See [primary keys](model-mapping.md#primary-keys) for examples and schema configuration.

To generate new UUID-based models:

```sh
bin/rails generate vouch:scope User --primary-key-type uuid
```

The UUID option changes the table declaration to `create_table :users, id: :uuid`; the remaining columns are unchanged.

Namespaced models are supported too:

```sh
bin/rails generate vouch:scope Staff::Operator --auth-scope operator
```

For that example, the generated model is `Staff::Operator`; the explicit scope gives `current_operator` and `/operators/sign_in`. Its table uses the same credential columns as the first migration.

## Check your setup

```sh
bin/rails vouch:verify
bin/rails routes
```

The verifier checks model associations, required columns, and delivery methods for enabled features. Rails lists the routes enabled by your configuration. [Controllers](controllers.md) covers overriding actions and copying their implementations into your application.
