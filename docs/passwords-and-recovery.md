# Password reset and recovery

## Add password reset

For an existing Vouch `User` model:

```sh
bin/rails generate vouch:password_resetable User
bin/rails db:migrate
```

This adds reset-token storage and methods to `User`, a `Users::PasswordResetsController`, request and replacement-password forms, routes, and `UserPasswordResetMailer`. The generated model delivery method calls that mailer. You do not need to write token-handling actions.

The migration adds:

```ruby
add_column :users, :password_reset_token_digest, :string
add_column :users, :password_reset_sent_at, :datetime
add_index :users, :password_reset_token_digest, unique: true
```

For a **multi-tenant application**, generate against the account:

```sh
bin/rails generate vouch:password_resetable Account
```

The same columns are added to `accounts`; the generated controller and routes use `accounts`. An account has one password. Resetting it changes the password used to sign in to that account, whichever organisation the person subsequently selects.

The generator infers the route scope and controller namespace. For a custom namespace:

```sh
bin/rails generate vouch:password_resetable User --auth-scope customer --controller-path portal
```

To generate only the model feature and the same reset-token schema, without pages:

```sh
bin/rails generate vouch:password_resetable User --model-only
```

### Customize the email

Edit the generated mailer to change the subject or recipient:

```ruby
# app/mailers/user_password_reset_mailer.rb
class UserPasswordResetMailer < ApplicationMailer
  def reset(user, token)
    @user = user
    @token = token
    mail(to: user.email_address, subject: "Choose a new password")
  end
end
```

Edit its template to change the message:

```erb
<%# app/views/user_password_reset_mailer/reset.text.erb %>
You requested a password reset.

Choose a new password: <%= edit_user_password_reset_url(token: @token) %>
```

The URL uses Action Mailer's `default_url_options`, for example:

```ruby
# config/environments/production.rb
config.action_mailer.default_url_options = { host: "app.example.com", protocol: "https" }
```

### Link to the form

```erb
<%= link_to "Forgot your password?", new_user_password_reset_path %>
```

| Step | Request | What happens |
| --- | --- | --- |
| Request form | `GET /users/password_reset/new` | Asks for the sign-in email. |
| Send link | `POST /users/password_reset` | Sends a reset link if the user exists; displays the same response either way. |
| Choose password | `GET /users/password_reset/edit?token=…` | Checks the link and displays the password form. |
| Save password | `PATCH /users/password_reset` | Validates and changes the password, then returns to sign-in. |

An invalid or expired link returns to sign-in. A password validation error redisplays the replacement-password form with its validation errors.

The request form submits `email_address`. If you identify users by `username` instead of `email_address`, change that field to `username` and register the corresponding [login resolver](setup.md#use-usernames-for-sign-in).

The replacement form submits `user[password]`, `user[password_confirmation]` and the reset token. It does not need the sign-in identifier again.

**Resetting a password does not bypass MFA.** It does not sign the person in or disable their second factor. Their next sign-in still requires MFA when enabled.

### Why a separate token implementation?

Rails' native `has_secure_password` reset tokens are signed tokens. Vouch additionally supports explicit revocation and replacement on reissue: requesting another reset immediately invalidates the earlier link.

Vouch stores a digest of a random token, locks the record when consuming it, and changes the password and clears the token together. Only one concurrent submission can consume a token successfully. Ordinary password updates also invalidate outstanding reset links. Callback-bypassing updates need equivalent invalidation in your own code.

The lookup method is named `find_by_auth_password_reset_token` to distinguish it from Rails' `find_by_password_reset_token` and its different token format.

### Replacing the supplied reset flow

Use these methods only when building your own endpoint or service. The generated controller already calls them:

```ruby
# Inside your password-reset service
result = user.generate_password_reset_token!
user.deliver_password_reset_token(result.value) if result.ok?
```

```ruby
# Inside your custom password-update action
token = params.require(:token)
password_params = params.require(:user).permit(:password, :password_confirmation)
user = User.find_by_auth_password_reset_token(token)
result = user&.reset_password_with_token!(token, **password_params.to_h.symbolize_keys)

if result&.ok?
  redirect_to new_user_session_path
else
  render :edit, status: :unprocessable_entity
end
```

Lookup returns `nil` for an invalid or expired token. `reset_password_with_token!` returns a `Vouch::Result`; `ok?` means the update succeeded. `user.clear_password_reset!` revokes a link without issuing another.

## Prevent password reuse

```sh
bin/rails generate vouch:password_trackable User
bin/rails db:migrate
```

The generator adds the `PasswordArchive` model, its table, the association on `User`, and the password-history feature. New passwords are checked against the current password and retained history.

The default migration creates a concrete owner relationship:

```ruby
create_table :password_archives do |t|
  t.bigint :account_id, null: false
  t.string :password_digest, null: false
  t.datetime :created_at, null: false
end
add_index :password_archives, [:account_id, :created_at]
add_foreign_key :password_archives, :users, column: :account_id
```

`account_id` refers to `users` in this example. The generator configures that association explicitly.

Configure how much history to retain:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :password_trackable,
    password_trackable: { history_count: 5, history_window: 1.year }
end
```

When several credentials models share an archive table, opt into polymorphic ownership:

```sh
bin/rails generate vouch:password_trackable User --polymorphic
```

That migration replaces the concrete owner with:

```ruby
t.references :account, polymorphic: true, null: false
```

It adds `account_type` and `account_id`, includes both in the history index and omits the concrete foreign key. The password digest and timestamp columns stay the same.

## Recover access after losing an MFA device

Password reset changes a password; it does not bypass MFA. [Recovery codes](recovery-codes.md) provide an alternate second factor after password authentication. You can enable codes owned by the account, an individual credential, or both.

For confirming an email address through a link, see [signed verification links](verification-and-mfa.md#signed-verification-links).

## Edit the reset actions

```sh
bin/rails generate vouch:eject users password_resets
```

The actions become editable in `app/controllers/users/password_resets_controller.rb`, retaining your controller customizations. [Ejection](controllers.md#eject-a-controller) explains which shared Vouch methods remain in use.
