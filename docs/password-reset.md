# Password reset

## Contents

- [Add password reset](#add-password-reset)
- [Customize the email](#customize-the-email)
- [Use the supplied flow](#use-the-supplied-flow)
- [Token revocation and expiry](#token-revocation-and-expiry)
- [Build a custom endpoint](#build-a-custom-endpoint)
- [Edit the reset actions](#edit-the-reset-actions)

## Add password reset

For an existing Vouch `User` model:

```sh
bin/rails generate vouch:password_resetable User
bin/rails db:migrate
```

This adds reset-token storage and methods to `User`, a `Users::PasswordResetsController`, request and replacement-password forms, routes, and `UserPasswordResetMailer`. The generated model delivery method calls that mailer. You do not need to write token-handling actions.

The migration adds:

```ruby
change_table :users do |t|
  t.string :password_reset_token_digest
  t.datetime :password_reset_sent_at
  t.index :password_reset_token_digest, unique: true
end
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

## Customize the email

Vouch's supplied `on_password_reset_token_generation` callback calls `user.deliver_password_reset_token(token)`. The generator adds that model method, which calls `UserPasswordResetMailer.reset(user, token).deliver_later`.

To change the delivery mechanism, override that model method. Registering another `on_password_reset_token_generation` callback adds behavior alongside the supplied callback and can send two emails; it does not replace it.


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

## Use the supplied flow

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

The request form submits `email_address`. If you identify users by `username` instead of `email_address`, change that field to `username` and register the corresponding [login resolver](sign-in-customization.md#use-usernames-for-sign-in).

The replacement form submits `user[password]`, `user[password_confirmation]` and the reset token. It does not need the sign-in identifier again.

**Resetting a password does not bypass MFA.** It does not sign the person in or disable their second factor. Their next sign-in still requires MFA when enabled.

## Token revocation and expiry

Rails' native `has_secure_password` reset tokens are signed tokens. Vouch additionally supports explicit revocation and replacement on reissue: requesting another reset immediately invalidates the earlier link.

Vouch stores a digest of a random token, locks the record when consuming it, and changes the password and clears the token together. Only one concurrent submission can consume a token successfully. Ordinary password updates also invalidate outstanding reset links. Callback-bypassing updates need equivalent invalidation in your own code.

The lookup method is named `find_by_auth_password_reset_token` to distinguish it from Rails' `find_by_password_reset_token` and its different token format.

## Build a custom endpoint

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


## Edit the reset actions

```sh
bin/rails generate vouch:eject users password_resets
```

This creates `app/controllers/users/password_resets_implementation_controller.rb` and makes your existing controller inherit from it. See [controller ejection](controllers.md#eject-a-controller).
