# Passwordless sign-in

## Contents

- [Add passwordless codes](#add-passwordless-codes)
- [Deliver a code](#deliver-a-code)
- [Complete a host endpoint](#complete-a-host-endpoint)

## Add passwordless codes

```sh
bin/rails generate vouch:magic_linkable Phone
bin/rails db:migrate
```

`MagicLinkable` issues and verifies a first-factor code. It adds a nonce, attempts, and lock timestamp to the credential, includes the model concern, and leaves the endpoint and Warden session to the host application.

The migration adds:

```ruby
change_table :phones do |t|
  t.string :sign_in_nonce
  t.bigint :sign_in_attempts, default: 0, null: false
  t.datetime :sign_in_locked_at
end
```

## Deliver a code

The generator adds a delivery hook. Implement it for the credential channel:

```ruby
# app/models/phone.rb
def deliver_sign_in_code(code)
  SmsService.deliver(e164, "Your sign-in code is #{code}")
end
```

An email credential can call a mailer instead. Normalize and validate the credential value before issuing the code.

## Complete a host endpoint

Your endpoint sends a code with `issue_sign_in_code!`, stores its result token in the Rails session, then verifies with `verify_sign_in_code(code, token:)`:

```ruby
result = phone.issue_sign_in_code!
session[:phone_sign_in_token] = result.token if result.ok?
```

```ruby
result = phone.verify_sign_in_code(params.require(:code), token: session[:phone_sign_in_token])

if result.ok?
  session.delete(:phone_sign_in_token)
  outcome = complete_sign_in(phone.user, method: :passwordless,
    hook: :sign_in, signed_in_via: phone)

  case outcome
  when :signed_in then redirect_after_authentication
  when :needs_two_factor then redirect_to two_factor_challenges_path
  when :needs_selection then redirect_to select_path
  else redirect_to new_user_session_path, alert: "Unable to sign in"
  end
else
  render :verify, status: :unprocessable_entity
end
```

After a successful proof, call the [custom authentication completion API](advanced-custom-authentication.md) with `signed_in_via: phone`. Handle `:needs_two_factor`, `:needs_selection`, `:no_identity`, and `:denied` as described there; the completion API applies policy and membership selection after the proof.

This is a model-level API for a host-defined endpoint. It is separate from verification and MFA token state; issuing a new code invalidates the earlier code for this operation. The supplied password, OAuth, and MFA controllers do not require this custom completion work.
