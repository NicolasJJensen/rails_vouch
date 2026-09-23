# Password reset and recovery

## Add password reset

For an existing Vouch `User` model:

```sh
bin/rails generate vouch:password_resetable User
bin/rails db:migrate
```

This adds reset-token storage and methods to `User`, a `Users::PasswordResetsController`, request and replacement-password forms, routes, and `UserPasswordResetMailer`. The generated model delivery method calls that mailer. You do not need to write token-handling actions.

For a multi-tenant login with credentials stored in `Account`, run the same command with `Account`. Password reset changes the credentials used across that account's memberships.

The generator infers the route scope and controller namespace. Supply `--auth-scope` or `--controller-path` when yours use different names. To generate only model support and schema, explicitly use:

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

An invalid or expired link returns to sign-in. A password validation error redisplays the form so the person can correct it. The request form submits top-level `email_address`; the replacement form submits `user[password]` and `user[password_confirmation]` with the token. If you use another sign-in identifier, update the request form to match your [login resolver](setup.md).

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
user = User.find_by_auth_password_reset_token(params[:token])
result = user&.reset_password_with_token!(params[:token],
  password: params[:password], password_confirmation: params[:password_confirmation])

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

Configure the history on the credentials model:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :password_trackable,
    password_trackable: { history_count: 5, history_window: 1.year }
end
```

Keep the model's existing features and associations. The generated archive belongs to the requested model. If several different credentials classes deliberately share one archive table, opt into `--polymorphic` when generating it.

## Account recovery codes

Recovery codes provide an alternative proof when someone loses access to their usual factor. They do not reset a password or create a session by themselves. Your recovery page decides how successful proof lets the person replace a lost factor.

```sh
bin/rails generate vouch:recoverable User
bin/rails db:migrate
```

In an authenticated recovery-settings action, generate a set and display the returned plaintext codes once:

```ruby
result = current_user.generate_recovery_codes!
@codes = result.value
```

A replacement set invalidates the earlier set. The database stores hashes. In your recovery action, after identifying the user through your recovery flow:

```ruby
result = user.consume_recovery_code!(params[:recovery_code])
if result.ok?
  # Continue your application's factor-replacement flow.
end
```

A code can be used once. Handle unsuccessful results, including lockout, before allowing factor changes. Do not treat a submitted user ID alone as authorization to change that user's credentials.

## Backup codes for one credential

`Vouch::BackupCodable` attaches codes to a particular MFA credential, rather than the whole account:

```sh
bin/rails generate vouch:backup_codes Phone
bin/rails db:migrate
```

The generator adds the backup-code model, table, and association to `Phone`. Generate a replacement set with `credential.regenerate_backup_codes!` and show its returned codes once. With `TwoFactorable` and `BackupCodable` on that credential, its normal challenge verification accepts an unused backup code too.

This is useful when the person still has their password but cannot receive that credential's current code. It differs from the account-recovery workflow above, which your application supplies.

## Signed verification links

Use `TokenVerifiable` to confirm a recipient through a clickable link, rather than reset a password:

```ruby
# app/models/email_confirmation.rb
class EmailConfirmation < ApplicationRecord
  include Vouch::TokenVerifiable::Concern
  self.token_subject_attribute = :email_address
end
```

The model needs `verified_at` and `confirmation_nonce` columns. After saving it, `confirmation.confirmation_token` produces a token for your delivery method. Your confirmation endpoint calls `EmailConfirmation.consume_token(token)` and checks `result.ok?`.

A successful confirmation consumes the token. Saving a recipient change invalidates earlier links and clears verification, even if the address later changes back. Without `token_subject_attribute`, the link verifies the record without binding it to a recipient field.
