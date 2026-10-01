# Sign-in and registration customization

Start with the [README setup](../README.md). The generated sign-in and registration views belong to your application. A login resolver finds the credentials record from submitted identifiers; Vouch checks that record's password afterward.

## Contents

- [Use a username, email or phone number](#use-a-username-email-or-phone-number)
- [Configure resolver lists](#configure-resolver-lists)
- [Customize registration fields](#customize-registration-fields)
- [Choose an onboarding destination](#choose-an-onboarding-destination)

## Use a username, email or phone number

This example extends a `User` credentials model with a username and an optional phone number. The email column from the scope generator uses PostgreSQL `citext`.

```ruby
# db/migrate/20261001000000_add_login_identifiers_to_users.rb
class AddLoginIdentifiersToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users do |t|
      t.citext :username, index: { unique: true }
      t.string :phone_number, index: { unique: true }
    end
  end
end
```

```ruby
# app/models/user.rb — add these declarations to the existing model
class User < ApplicationRecord
  normalizes :username, with: ->(value) { value.strip.downcase }
  validates :username, uniqueness: true, allow_nil: true
end
```

> Store phone numbers in a consistent format, such as E.164. The phone resolver below expects that format; it does not parse national phone numbers or verify ownership of a number.

Each resolver checks the same `login` input. Keeping lookups separate lets Vouch detect when the input identifies different accounts.

```ruby
# lib/username_resolver.rb
class UsernameResolver < Vouch::LoginResolver::Base
  def valid?(params)
    params[:login].present?
  end

  def resolve!(params, account_class)
    account = account_class.find_by(username: params[:login].to_s.strip.downcase)
    account ? success!(account) : fail!
  end
end
```

```ruby
# lib/phone_resolver.rb
class PhoneResolver < Vouch::LoginResolver::Base
  def valid?(params)
    params[:login].present?
  end

  def resolve!(params, account_class)
    account = account_class.find_by(phone_number: params[:login].to_s.strip)
    account ? success!(account) : fail!
  end
end
```

```ruby
# config/initializers/vouch.rb — edit the generated configuration
require_relative "../../lib/username_resolver"
require_relative "../../lib/phone_resolver"

Vouch.configure do |config|
  config.login_resolvers = [Vouch::LoginResolver::EmailResolver]
  config.login_resolvers_for "User", with: [
    UsernameResolver,
    Vouch::LoginResolver::EmailResolver,
    PhoneResolver
  ]
end
```

The model-specific list keeps these extra lookups away from other credentials models that do not have username or phone columns. The built-in email resolver accepts `email_address`, `login` or `email`, trims whitespace and uses case-insensitive equality against `citext`.

```erb
<%# app/views/users/sessions/new.html.erb %>
<% if flash[:alert] %>
  <p role="alert"><%= flash[:alert] %></p>
<% end %>

<%= form_with scope: :user, url: user_session_path do |form| %>
  <%= form.label :login, "Username, email or phone number" %>
  <%= form.text_field :login, autocomplete: "username", required: true %>
  <%= form.label :password %>
  <%= form.password_field :password, autocomplete: "current-password", required: true %>
  <%= form.submit "Sign in" %>
<% end %>
```

This submits `user[login]` and `user[password]`. Vouch extracts the credentials model's parameter scope and supplies a flat hash to the resolvers. For an `Account` credentials model, use `account[...]`; namespaced models use their Rails model parameter key. Direct flat credential submissions remain accepted; a supplied model-scoped hash takes precedence as a whole.

Resolvers run in list order. A non-match allows the next resolver to run. If multiple resolvers find the same record, Vouch checks its password once. If they find different records, sign-in fails: a username matching someone else's email must not silently select one owner. A wrong password never causes another account's password to be tried.

> A custom resolver that searches several identifier columns must also reject conflicting owners. Combining lookups with `first_match || second_match` hides ambiguity from Vouch.

## Configure resolver lists

Assigning a list replaces it; repeating configuration does not append duplicates. To remove a resolver, assign the list you want to keep:

```ruby
# config/initializers/vouch.rb — inside the existing configuration block
Vouch.configure do |config|
  config.login_resolvers_for "User", with: [Vouch::LoginResolver::EmailResolver]
end
```

An explicit empty model list disables resolver lookup for that model. Resetting the override restores the global list instead:

```ruby
# config/initializers/vouch.rb — alternative configuration choices
Vouch.configure do |config|
  config.login_resolvers_for "User", with: []
  # To use the global list again, replace the line above with:
  # config.reset_login_resolvers_for "User"
end
```

Use `config.login_resolvers = []` to empty the global list. Existing authenticated sessions and independent OAuth sign-in are unaffected. Password-reset requests also use identifier resolution; an empty list prevents new requests from locating a credentials record, but does not itself revoke an existing reset token.

## Customize registration fields

Add fields to the generated registration form and permit them in its controller. Extend `super` so inherited OAuth parameter handling remains intact:

```ruby
# app/controllers/users/registrations_controller.rb
class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def account_params
    super.merge(params.require(auth_mapping.account_param_key).permit(:username))
  end

  def invited_account_params
    super.merge(params.require(auth_mapping.account_param_key).permit(:username))
  end
end
```

Invited registration uses its separate parameter method. Do not permit provider IDs, verification state or continuation tokens as ordinary model fields. For associated records and tenant construction, see [registration](registration.md).

## Choose an onboarding destination

Put a shared destination in `ApplicationController` so it also applies when MFA or membership selection completes registration in another controller:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  def after_sign_up_path_for(record, scope:)
    onboarding_path
  end
end
```

> `onboarding_path` is a page supplied by your application. See [registration redirects](registration.md#send-people-to-onboarding) for the complete flow.

Use [lifecycle hooks](sessions-and-hooks.md#lifecycle-hooks) for accompanying work: transactional signup hooks for related database records and commit hooks for external notifications.
