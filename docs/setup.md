# Setup and customization

For email/password sign-in with a `User` model:

```sh
bin/rails generate vouch:install
bin/rails generate vouch:scope users User --single-model
bin/rails db:migrate
```

The scope generator creates the model, migration, controllers, forms, and routes. Customize the generated files as you would other Rails application code.

## Use another model name

For an application that calls its users `Member`:

```sh
bin/rails generate vouch:scope members Member --single-model
```

This gives you `current_member`, `member_signed_in?`, and `authenticate_member!`, with sign-in at `/members/sign_in`. The scope name identifies the login; the model argument identifies the record it authenticates.

For accounts with organisation memberships, follow [model mapping](model-mapping.md#organisation-memberships).

## Add features

Run feature generators against the model that holds the password:

```sh
bin/rails generate vouch:password_resetable User
bin/rails generate vouch:password_trackable User
bin/rails generate vouch:omniauth User --provider github
bin/rails db:migrate
```

Each feature has a guide covering its generated files and customization: [password resets](passwords-and-recovery.md), [OAuth](oauth.md), [MFA](verification-and-mfa.md), and [invitations](invitations.md).

Use `--auth-scope` when the same model serves several login scopes. Use `--controller-path` to place generated controllers in a custom namespace. These are overrides; ordinary setups infer both values.

For just the password-reset model feature and migration:

```sh
bin/rails generate vouch:password_resetable User --model-only
```

## Use usernames for sign-in

Email addresses are the default. You can instead find users by another attribute. This example keeps email for password-reset delivery but uses a unique `username` to sign in.

Generate a column, then add a unique index in its migration:

```sh
bin/rails generate migration AddUsernameToUsers username:string
```

```ruby
add_index :users, :username, unique: true
```

Backfill usernames before enforcing presence on existing records.

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
bin/rails generate vouch:scope users User --single-model --primary-key-type uuid
```

Namespaced models are supported too:

```sh
bin/rails generate vouch:scope operators Staff::Operator --single-model
```

## Check your setup

```sh
bin/rails vouch:verify
bin/rails routes
```

The verifier checks model associations, required columns, and delivery methods for enabled features. Rails lists the routes enabled by your configuration. [Controllers](controllers.md) covers overriding actions and copying their implementations into your application.
