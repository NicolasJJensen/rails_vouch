# Password reset

## Contents

- [Add password reset](#add-password-reset)
- [Use the supplied flow](#use-the-supplied-flow)
- [Customize delivery](#customize-delivery)
- [Choose who can reset a password](#choose-who-can-reset-a-password)
- [Choose token storage](#choose-token-storage)
- [Change the recovery destination](#change-the-recovery-destination)
- [Customize responses and token operations](#customize-responses-and-token-operations)
- [Edit the reset actions](#edit-the-reset-actions)

## Add password reset

For an existing Vouch `User` model:

```sh
bin/rails generate vouch:password_resetable User
bin/rails db:migrate
```

The generator adds:

- A migration and reset-token methods to the `User` model.
- `Users::PasswordResetsController` and the request and password reset forms.
- Password reset routes.
- `UserPasswordResetMailer`, its template, and a model method for delivery.

The default signed-token migration adds:

```ruby
change_table :users do |t|
  t.string :password_reset_nonce
end
```

It also configures the model:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :password_resetable, password_resetable: { token_strategy: :signed }
end
```

In a **multi-tenant application**, pass the model that stores the password. For example, when that model is `Account`:

```sh
bin/rails generate vouch:password_resetable Account
```

The migration adds `password_reset_nonce` to `accounts` instead. Resetting this password changes how the person signs in; it does not change their memberships.

For a custom controller namespace and authentication scope:

```sh
bin/rails generate vouch:password_resetable User --auth-scope customer --controller-path portal
```

To generate the migration and model configuration only:

```sh
bin/rails generate vouch:password_resetable User --model-only
```

`--model-only` omits the controller, views, routes, mailer and delivery method.

## Use the supplied flow

```erb
<%# Your sign-in view %>
<%= link_to "Forgot your password?", new_user_password_reset_path %>
```

| Step | Request | Behavior |
| --- | --- | --- |
| Request form | `GET /users/password_reset/new` | Asks for the sign-in email. |
| Send link | `POST /users/password_reset` | Sends a link to an eligible user, then returns to sign-in with a generic notice. |
| Choose password | `GET /users/password_reset/edit?token=…` | Checks the token and displays the password reset form. |
| Save password | `PATCH /users/password_reset` | Validates and changes the password, then returns to sign-in. |

Unknown users, ineligible users and expected delivery failures receive the same request response. Delivery failures are reported through `Rails.error`. Invalid or expired links return to sign-in; password validation errors appear on the password reset form.

The request form submits `email_address`. If your sign-in identifier is something else, such as `username`, update the form, [login resolver](sign-in-customization.md), and permitted request parameters:

```ruby
# app/controllers/users/password_resets_controller.rb
class Users::PasswordResetsController < Vouch::PasswordResetsController
  private

  def password_reset_params
    params.permit(:username)
  end
end
```

The password reset form submits `user[password]`, `user[password_confirmation]` and `token`.

> Resetting a password does not sign the person in or disable MFA. Their next sign-in follows the usual authentication flow.

## Customize delivery

The generated controller's `on_password_reset_token_generation` callback calls `user.deliver_password_reset_token(token, recipient: recipient)`. Edit that model method to change delivery, or edit the generated mailer and template:

```ruby
# app/mailers/user_password_reset_mailer.rb
class UserPasswordResetMailer < ApplicationMailer
  def reset(user, token, recipient:)
    @user = user
    @token = token
    mail(to: recipient, subject: "Choose a new password")
  end
end
```

```erb
<%# app/views/user_password_reset_mailer/reset.text.erb %>
You requested a password reset.
Choose a new password: <%= edit_user_password_reset_url(token: @token) %>
```

The controller captures `recipient` when it issues the token. Keep passing that value to the mailer: a queued email must not change recipients because the user's email changed while the job was waiting.

> Registering another `on_password_reset_token_generation` callback adds behavior; it does not replace the existing callback. Edit the generated delivery method to avoid sending two emails.

## Choose who can reset a password

By default, only accounts with a password are eligible. Accounts awaiting invited registration are also excluded when invitations are enabled for their credentials model.

Override `password_reset_accounts` to add your application's restrictions. Vouch applies this relation when resolving the request, opening the link and changing the password:

```ruby
# app/controllers/users/password_resets_controller.rb
class Users::PasswordResetsController < Vouch::PasswordResetsController
  private

  def password_reset_accounts
    super.where(suspended: false) # An attribute supplied by this application.
  end
end
```

An application that deliberately allows OAuth-only users to set their first password can remove just the password restriction with `super.unscope(where: :password_digest)`. This preserves the pending-invitation restriction. A custom login resolver cannot bypass the relation.

## Choose token storage

Both strategies expire tokens, revoke earlier links when another is requested, and revoke links when the password changes. Tokens can be consumed only once, including concurrent submissions.

| Strategy | Storage | Tradeoff |
| --- | --- | --- |
| `signed` (default) | `password_reset_nonce` | A signed token carries its expiry and password fingerprint; the database nonce enables explicit revocation. |
| `opaque` | `password_reset_token_digest`, `password_reset_sent_at` | A random token is represented by a digest and issuance time in the database. |

To select opaque tokens:

```sh
bin/rails generate vouch:password_resetable User --token-strategy opaque
bin/rails db:migrate
```

The generator updates the model's `token_strategy` and supplies this schema:

```ruby
change_table :users do |t|
  t.string :password_reset_token_digest, index: { unique: true }
  t.datetime :password_reset_sent_at
end
```

Rerunning with another strategy creates the required migration and revokes outstanding links. Existing columns are retained; the configured strategy never falls back to another format.

Configure expiry alongside the strategy:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  authenticates_with :password_resetable,
    password_resetable: { token_strategy: :signed, expiry: 30.minutes }
end
```

> Rails' password reset tokens are signed and bound to the password. Vouch additionally stores revocation state, so an unchanged password does not prevent explicit revocation or revocation when a replacement link is sent.

## Change the recovery destination

Updating the baseline `email_address` revokes outstanding reset links automatically. If your application selects an associated contact, override `password_reset_recipient` to return that selected address. Revoke links when the selection changes, or when that contact changes or is deleted, in the same database transaction as the change.

This example lets each `User` choose one of their verified `Email` records. The foreign key identifies the selected record; the ownership check prevents selecting another person's email.

```ruby
# db/migrate/20261001000000_add_recovery_contacts.rb
class AddRecoveryContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :emails do |t|
      t.references :user, null: false, foreign_key: true
      t.citext :address, null: false
      t.datetime :verified_at
      t.timestamps
    end

    add_reference :users, :primary_email, foreign_key: { to_table: :emails }
  end
end
```

The application models enforce selection ownership and revoke outstanding links when the destination stops being usable:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_many :emails, dependent: :destroy
  belongs_to :primary_email, class_name: "Email", optional: true

  validate :primary_email_belongs_to_user
  after_update :revoke_reset_after_destination_selection,
    if: :saved_change_to_primary_email_id?

  private

  def primary_email_belongs_to_user
    return if primary_email_id.nil?
    errors.add(:primary_email, "must be one of your verified emails") unless
      emails.where.not(verified_at: nil).exists?(id: primary_email_id)
  end

  def revoke_reset_after_destination_selection
    clear_password_reset!
  end
end
```

```ruby
# app/models/email.rb
class Email < ApplicationRecord
  belongs_to :user
  normalizes :address, with: ->(value) { value.strip.downcase }

  before_update :revoke_selected_reset_links, if: :recovery_contact_changed?
  before_destroy { revoke_selected_reset_links(clear_selection: true) }

  private

  def recovery_contact_changed?
    will_save_change_to_address? || will_save_change_to_verified_at? ||
      will_save_change_to_user_id?
  end

  def revoke_selected_reset_links(clear_selection: false)
    User.where(primary_email_id: id).order(:id).each do |owner|
      owner.with_lock do
        next unless owner.primary_email_id == id
        if clear_selection || will_save_change_to_user_id?
          owner.update!(primary_email: nil)
        else
          owner.clear_password_reset!
        end
      end
    end
  end
end
```

```ruby
# app/controllers/users/password_resets_controller.rb
class Users::PasswordResetsController < Vouch::PasswordResetsController
  private

  def password_reset_recipient
    @user.emails.where.not(verified_at: nil)
      .find_by(id: @user.primary_email_id)&.address
  end
end
```

Changing the selection, address, owner, or verification state revokes existing links. Deleting a selected email also clears the selection. Changing an unrelated email does not revoke the selected destination’s link. These callbacks work with both signed and opaque tokens and must use the same writing connection as `User`.

The controller captures the selected address while holding the user lock. Pass that captured `recipient:` to the generated mailer even if delivery runs later; never look up `primary_email` again in the mailer. A later contact change revokes the old token without redirecting its queued message to another address.

> `update_columns`, `update_all`, direct SQL and other callback-bypassing changes also bypass revocation. Revoke the token explicitly in the same transaction when using them.

## Customize responses and token operations

Call `super` to perform the operation, then use its status to choose a response. The affected record is available as `@user` for the `:user` scope (`@account` for an `:account` scope):

```ruby
# app/controllers/users/password_resets_controller.rb
class Users::PasswordResetsController < Vouch::PasswordResetsController
  def update
    status = super
    redirect_to new_user_session_path, notice: "Password changed." if status == :ok
  end
end
```

If your action does not respond, Vouch's `default_render` runs after it finishes. A successful reset returns to sign-in; invalid passwords redisplay the form with `@user.errors`, and an invalid token returns to sign-in. Recognized failures return statuses such as `:invalid` or `:cancelled`; `@operation_error` contains an underlying exception when available.

> The request action's default response stays the same whether a user exists, is eligible, or an expected delivery failure occurs. Preserve that behavior when customizing `create` so the endpoint does not disclose registered email addresses.

For a custom service, the model operations are:

| Operation | Result-returning method | Raising method |
| --- | --- | --- |
| Issue a token | `generate_password_reset_token` | `generate_password_reset_token!` |
| Change the password | `reset_password_with_token(token, **attributes)` | `reset_password_with_token!(token, **attributes)` |
| Revoke a token | `clear_password_reset` | `clear_password_reset!` |

Successful calls return a `Vouch::Result`. The issuance result's `value` is the plaintext token. Non-bang methods return unsuccessful results for validation or persistence cancellation; bang methods raise `Vouch::OperationFailed`, whose `result` retains the record and error. Unexpected exceptions propagate.

`User.find_by_auth_password_reset_token(token)` returns the user or `nil`. Custom endpoints must apply their own eligibility relation as the supplied controller does.

## Edit the reset actions

```sh
bin/rails generate vouch:eject users password_resets
```

This creates `app/controllers/users/password_resets_implementation_controller.rb` and makes your controller inherit from it. The generated views and mailer are already editable application files. See [controller ejection](controllers.md#eject-a-controller).
