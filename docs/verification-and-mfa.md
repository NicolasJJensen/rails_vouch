# Verification and multi-factor authentication

Verification checks that someone controls a phone number or email address. MFA uses a verified credential as a second proof when signing in.

## Add phone-based MFA

Starting with a Vouch `User` model:

```sh
bin/rails generate model Phone user:references e164:string
bin/rails generate vouch:two_factorable Phone --subject e164
bin/rails db:migrate
```

The generator reads `Phone`'s owner association and wires MFA into `User`. It adds verification and challenge fields to `Phone`, the account-level MFA flag to `User`, the model concerns and associations, challenge and enrollment controllers and forms, and `auth.two_factor` routes.

`--subject e164` identifies the field whose value is verified. The generator adds this declaration:

```ruby
# app/models/phone.rb
self.verifiable_subject_attribute = :e164
```

Changing that field clears verification and invalidates outstanding codes. A verified old number must not make its replacement trusted.

For a multi-tenant application, use `account:references` when creating `Phone`; MFA protects the `Account` that owns the credentials. Use `--auth-scope` or `--controller-path` only to override names that differ from your model and route conventions. `--model-only` generates model support without controllers or views.

### Connect your SMS delivery

The generator adds delivery methods that raise until you implement them. Replace their bodies with your SMS integration:

```ruby
# app/models/phone.rb
 def deliver_verification_code(code)
   SmsService.deliver(e164, "Your verification code is #{code}")
 end

 def deliver_two_factor_code(code)
   SmsService.deliver(e164, "Your sign-in code is #{code}")
 end
```

`SmsService` represents a service you implement using your SMS provider. Add phone normalization and validation to `Phone` as appropriate for the numbers you accept.

### Enroll a phone

Link to the generated credential-management page:

```erb
<%= link_to "Manage two-factor authentication", user_two_factor_credentials_path %>
```

The generated flow saves a phone under the signed-in user, sends a verification code, and asks for that code. A successful verification enables the phone as a factor and enables MFA for the user. An incorrect code leaves the confirmation form available for another attempt.

The generated controller is yours to customize. It must look up credentials through the signed-in user's association, so another user's credential ID cannot be used to enroll or remove a factor.

## Sign in with MFA

For a user with MFA enabled:

1. They submit their email and password to the normal sign-in form.
2. Vouch asks them to choose one of their usable factors.
3. Selecting the phone sends a sign-in code. Submitting the correct code finishes sign-in and returns to the requested page or configured redirect.

A correct password alone does not establish the completed login. An incorrect code redisplays the challenge; an expired challenge needs a new code. Repeated failures can lock the factor. Disabled or unverified credentials cannot complete MFA.

In a multi-tenant setup, MFA completes before membership selection. Someone with one eligible membership continues immediately; someone with several chooses which organisation to enter.

[Password reset](passwords-and-recovery.md) does not disable this requirement. [Recovery codes](passwords-and-recovery.md#account-recovery-codes) provide a separate way to recover access after losing a factor.

## Verify more than one attribute

When several fields together identify the recipient, configure them as an array:

```ruby
# app/models/email_address.rb
self.verifiable_subject_attribute = [:local_part, :domain]
```

Or generate that configuration with:

```sh
bin/rails generate vouch:two_factorable EmailAddress --subject local_part domain
```

Both values are bound to the verification. Changing either invalidates existing codes and clears verification, including changing a value away and back. Attribute aliases are supported. The fields remain separate values, so combinations such as `ab` + `c` and `a` + `bc` are not treated as the same subject.

## Verification without MFA

To verify a credential without making it a sign-in factor:

```sh
bin/rails generate vouch:verifiable Phone --subject e164
bin/rails db:migrate
```

Implement its delivery method, then call these methods from your own verification actions:

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

## Control factor availability

`phone.enable_two_factor!` enables an already verified factor. `user.enable_two_factor!` enables the account requirement and checks that a usable factor exists.

Removing or disabling the last usable factor is prevented by default: Vouch raises `Vouch::TwoFactorable::LastFactorRemoval`. To let removal disable the account’s MFA requirement, define this method on the credentials owner:

```ruby
# app/models/user.rb
 def two_factor_last_factor_removal_action(_credential)
   :disable
 end
```

Only choose that behavior when your application permits users to turn MFA off.

## Other factors

TOTP uses the optional `rotp` dependency and requires enrollment and QR-code presentation in your application. Custom factors must preserve verification, lockout, and single-use behavior; the [credential adapter contract](credential-adapter-contract.md) provides shared specs.

Verification, magic-link sign-in, and MFA challenges have separate token state. Issuing a replacement challenge invalidates its predecessor. For magic-link sign-in, install `Vouch::MagicLinkable` and its schema separately and implement `deliver_sign_in_code`.
