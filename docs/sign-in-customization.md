# Sign-in and registration customization

Generated sign-in and registration forms are ordinary application views. Edit them first; customize the generated controller when parameters, record construction, or redirects change.

## Contents

- [Use usernames for sign-in](#use-usernames-for-sign-in)
- [Customize the registration form](#customize-the-registration-form)
- [Build a tenant and membership](#build-a-tenant-and-membership)
- [Post-signup onboarding](#post-signup-onboarding)

## Use usernames for sign-in

Email is the supplied login resolver. This example keeps email for reset delivery and uses a unique `username` for sign-in.

```ruby
def change
  change_table :users do |t|
    t.string :username
    t.index :username, unique: true
  end
end
```

```ruby
# app/models/user.rb
normalizes :username, with: ->(value) { value.strip.downcase }
validates :username, presence: true, uniqueness: { case_sensitive: false }
```

```ruby
# lib/username_resolver.rb
class UsernameResolver < Vouch::LoginResolver::Base
  def valid?(params) = params[:username].present?

  def resolve!(params, account_class)
    account = account_class.find_by(username: params[:username].to_s.strip.downcase)
    account ? success!(account) : fail!
  end
end
```

Replace the generated `EmailResolver` line with this ordered pair, and load
the class in the initializer:

```ruby
require_relative "../../lib/username_resolver"

Vouch.configure do |config|
  config.register_login_resolver UsernameResolver
  config.register_login_resolver Vouch::LoginResolver::EmailResolver
end
```

This replaces the existing registration rather than appending a second
`EmailResolver`. Resolvers run in registration order. A request containing
both fields gives `UsernameResolver` priority; `fail!` then allows
`EmailResolver` to try. A successful lookup stops lookup and Vouch checks that
account's password. A wrong password never tries another account.

Change the generated sign-in form to submit `username`. Keeping
`EmailResolver` lets the generated password-reset form continue to find an
account by `email_address`. If email is removed entirely, replace password
reset and invitation lookup and delivery with your own identifier and delivery
channel.

## Customize the registration form

Add fields to the generated form, then permit the corresponding account attributes:

```ruby
class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def account_params
    params.require(:user).permit(:username, :email_address, :password, :password_confirmation)
  end
end
```

The ordinary registration flow builds the account from `account_params`, validates it, and saves it inside Vouch’s registration transaction. Do not put provider IDs, invitation tokens, or session continuation data in form parameters.

## Build a tenant and membership

For the generated nested `Account` / `User` / `Organisation` setup, the registration form can include an organisation name. Construct unsaved records; Vouch saves the account, tenant, and identity together.

```ruby
class Accounts::RegistrationsController < Vouch::RegistrationsController
  private

  def build_tenant(_account)
    Organisation.new(params.require(:organisation).permit(:name))
  end

  def build_identity(account, tenant:)
    tenant.users.build(account: account)
  end
end
```

This is construction inside registration, not onboarding after registration. Keep it limited to records whose failure must reject the signup.

## Post-signup onboarding

Choose the completed signup destination in the registrations controller:

```ruby
def after_sign_up_path
  onboarding_path
end
```

Use `after_commit_of_sign_up` for an external welcome email or analytics call. Use `after_sign_up` for database records that must roll back with signup. See [lifecycle hooks](sessions-and-hooks.md#lifecycle-hooks) for the timing and [registration](registration.md) for OAuth continuation details.
