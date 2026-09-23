# Password reset and recovery

Password reset lets someone who cannot sign in choose a new password through an emailed link. Vouch supplies the token lifecycle, controller actions, and forms. The application configures email delivery and password validation.

## Add password reset

Start with an existing Vouch credentials model and account scope. For `Account` under the `:account` scope:

```sh
bin/rails generate vouch:password_resetable Account --auth-scope account --controller-path accounts
bin/rails db:migrate
```

For a single-model `User` login, use:

```sh
bin/rails generate vouch:password_resetable User --auth-scope user --controller-path users
bin/rails db:migrate
```

The generator adds:

- A migration for `password_reset_token_digest` and `password_reset_sent_at`.
- `authenticates_with :password_resetable` on the credentials model.
- A passwords controller, request form, and new-password form.
- `auth.passwords` inside the selected route scope when the route block can be identified safely.
- A model-specific password-reset mailer and email template, plus the delivery hook that invokes it.

Read any generator message about routes or a model it could not update. Those messages show the remaining addition rather than silently creating incomplete wiring. Retain the model's existing `has_secure_password` and validation configuration.

If you only want the schema/model feature, omit both UI options. That does not generate a controller, views, or mailer.

## Configure email delivery

The generated email links to `edit_account_password_url(token: token)` (or the selected scope's equivalent). Configure Action Mailer delivery and an application host. For example, in your environment configuration:

```ruby
config.action_mailer.default_url_options = {
  host: "app.example.com",
  protocol: "https"
}
```

Use your application's real host and email provider. Configure the sender in `ApplicationMailer`, then customize the generated mailer and template.

The generated controller connects token creation to delivery:

```ruby
class Accounts::PasswordsController < Vouch::PasswordsController
  auth_scope :account

  on_password_reset_token_generation do |account, token|
    account.deliver_password_reset_token(token)
  end
end
```

You do not need to generate, look up, or consume tokens in application controllers. Vouch's passwords controller already performs those operations.

## Offer the reset flow

Link to the request form wherever your application offers password recovery:

```erb
<%= link_to "Forgot your password?", new_account_password_path %>
```

The generated flow is:

1. `GET /accounts/password/new` displays the email form.
2. `POST /accounts/password` accepts top-level `email_address`, issues a token for a matching account, and runs delivery. Its response does not disclose whether the account exists.
3. The email opens `/accounts/password/edit?token=…`.
4. The new-password form submits `PATCH /accounts/password`, including `token` and `account[password]` / `account[password_confirmation]`.
5. A successful reset redirects to account sign-in. It does not create an authenticated session.

The nested parameter key comes from the credentials model's `model_name.param_key`; it is `user` for a single-model `User`. Invalid links return to sign-in. Password validation failures render the form with status 422 and leave the token available for a corrected submission.

Password policy and request rate limits belong to the application. For a custom login identifier, update the request form and login resolver as described in [setup](setup.md#non-email-identifiers).

## Why Vouch uses its own reset tokens

Rails' `has_secure_password` offers signed reset tokens. Vouch uses a random token with a database-stored SHA-256 digest because its contract additionally requires **explicit revocation and replacement on reissue**: requesting a new reset immediately invalidates the previous reset link.

Consumption locks the account, rechecks token validity and expiry, changes the password, and clears the token state in the same transaction. This also prevents two concurrent requests from consuming the same reset token successfully.

Only the digest is persisted. The raw token is passed to delivery. Normal Active Record password updates clear outstanding reset state, including updates outside this controller. Callback-bypassing writes such as `update_columns` or direct SQL require equivalent invalidation by the application.

Vouch's tokens and Rails' signed tokens are different formats. `find_by_auth_password_reset_token` deliberately has a separate name so it cannot collide with Rails' `find_by_password_reset_token`.

## Custom reset integrations

Only applications replacing the supplied web flow need the lower-level API. For example, a custom service can issue and deliver a token:

```ruby
result = account.generate_password_reset_token!
account.deliver_password_reset_token(result.value) if result.ok?
```

A custom endpoint can look up and consume it:

```ruby
account = Account.find_by_auth_password_reset_token(token)
result = account&.reset_password_with_token!(token,
  password: new_password,
  password_confirmation: confirmation)
```

Handle a missing account and unsuccessful results explicitly. Lookup returns `nil` for invalid or expired tokens. Consumption returns a `Vouch::Result`; `.ok?` means the password was changed. To revoke a reset without replacing it, call `account.clear_password_reset!`.

These APIs do not replace endpoint authorization, delivery, or rate limits.

## Password history

The optional `password_trackable` feature rejects reuse of the current password and configured archived passwords. Generate its schema:

```sh
bin/rails generate vouch:password_trackable Account
bin/rails db:migrate
```

Add the archive model and account association:

```ruby
class PasswordArchive < ApplicationRecord
  include Vouch::PasswordArchive::Concern
  belongs_to :account, polymorphic: true
end

class Account < ApplicationRecord
  has_many :password_archives, as: :account, dependent: :destroy
  authenticates_with :password_trackable
end
```

Configure association selection on the account model, so every authentication scope using that account applies the same password-history policy. [Model mapping](model-mapping.md) covers explicit association selection.

## Recovery codes and signed links

Account recovery codes (`Recoverable`) and per-credential backup codes (`BackupCodable`) are separate features. Display newly generated plaintext codes once; persist only their hashes. The application provides recovery UI, authorization, and rate limiting.

When a credential includes `TwoFactorable` and `BackupCodable`, its backup codes can satisfy `verify_challenge`; successful consumption also clears failed-factor state. Custom flows using `consume_backup_code!` must enforce their own eligibility and authorization checks.

Signed `TokenVerifiable` links are useful for recipient verification, not password resets. Configure the recipient attribute explicitly:

```ruby
class EmailConfirmation < ApplicationRecord
  include Vouch::TokenVerifiable::Concern
  self.token_subject_attribute = :email_address
end
```

Generate tokens only for persisted records. Saved recipient changes clear verification and rotate the nonce, including changing A to B and back to A. Without a subject attribute, tokens have record-bound semantics. The application owns delivery, route authorization, and invalidation for writes that bypass callbacks.
