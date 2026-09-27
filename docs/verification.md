# Verification

Verification proves control of a phone number or email address. It does not sign the person in or enable MFA.

## Contents

- [Verification without MFA](#verification-without-mfa)
- [Signed verification links](#signed-verification-links)

## Verification without MFA

For an existing `Phone` model with an owner association, an `e164` field, and timestamps:

```sh
bin/rails generate vouch:verifiable Phone --subject e164
bin/rails db:migrate
```

Its migration adds only the verification fields:

```ruby
change_table :phones do |t|
  t.string :verification_nonce
  t.datetime :verified_at
  t.bigint :verification_version, default: 0, null: false
  t.bigint :verification_attempts, default: 0, null: false
  t.datetime :verification_locked_at
  t.index :verified_at
end
```

The generator includes `Vouch::Verifiable` and adds `self.verifiable_subject_attribute = :e164` to the model. That declaration binds verification to the phone number: changing it clears verification and invalidates earlier codes. Use an array such as `[:local_part, :domain]` when several fields identify the recipient.

Verification-only setup does not generate pages. Implement delivery:

```ruby
# app/models/phone.rb
def deliver_verification_code(code)
  SmsService.deliver(e164, "Your verification code is #{code}")
end
```

`SmsService` is your SMS integration. In your verification actions, look up the phone through the authenticated owner's association, then issue and verify a code:

```ruby
# After saving a phone through the current user's association
result = phone.start_verification!
session[:phone_verification_token] = result.token if result.ok?
```

```ruby
result = phone.complete_verification!(params[:code], token: session[:phone_verification_token])
if result.ok?
  session.delete(:phone_verification_token)
  redirect_to profile_path
else
  render :verify, status: :unprocessable_entity
end
```

Use separate session entries per credential if your UI permits concurrent verification attempts. Verification alone does not enable MFA.


## Signed verification links

Use a signed link when the recipient should confirm an email address by opening a link and submitting a confirmation, rather than entering a numeric code. For an existing `EmailConfirmation` model with an `email_address` field and timestamps:

```sh
bin/rails generate vouch:token_verifiable EmailConfirmation
bin/rails db:migrate
```

For an existing `email_confirmations` table, the migration adds:

```ruby
change_table :email_confirmations do |t|
  t.datetime :verified_at
  t.string :confirmation_nonce
  t.index :verified_at
  t.index :confirmation_nonce, unique: true
end
```

Configure the model and the recipient field:

```ruby
class EmailConfirmation < ApplicationRecord
  include Vouch::TokenVerifiable::Concern
  self.token_subject_attribute = :email_address
  self.token_validity = 1.day
end
```

You supply the mailer and endpoint for this model-level feature. After saving the confirmation, pass `confirmation.confirmation_token` to your mailer and include it in the confirmation URL:

```erb
<%= link_to "Confirm email", email_confirmation_url(token: @token) %>
```

```ruby
# config/routes.rb
resource :email_confirmation, only: [:show, :update]
```

```ruby
class EmailConfirmationsController < ApplicationController
  def show
    @token = params.require(:token)
  end

  def update
    result = EmailConfirmation.consume_token(params.require(:token))
    if result.ok?
      redirect_to root_path, notice: "Email confirmed"
    else
      redirect_to root_path, alert: "The confirmation link is invalid or expired"
    end
  end
end
```

```erb
<%# app/views/email_confirmations/show.html.erb %>
<%= button_to "Confirm email", email_confirmation_path, method: :patch, params: { token: @token } %>
```

Vouch checks the signature, expiry, recipient and record nonce. Successful consumption marks the record verified and rotates its nonce, so the link cannot be reused. Changing `email_address` invalidates earlier links and clears verification. This flow verifies the email; it does not sign the person in.


To also use a verified credential during sign-in, follow [MFA setup](mfa.md).
