# Verification and multi-factor authentication

Verification proves control of a credential, such as a phone number. MFA requires a verified credential as an additional proof during account sign-in. They are separate steps: verifying a phone does not automatically enable account MFA.

The example below uses a phone credential. Your application supplies the SMS service and enrollment pages.

## Add a credential model and schema

For an existing `Account` credentials model:

```sh
bin/rails generate model Phone account:references e164:string
bin/rails generate vouch:verifiable Phone
bin/rails generate vouch:two_factorable Phone --auth-scope account --controller-path accounts
bin/rails generate migration AddTwoFactorEnabledToAccounts
```

Put this in the new account migration's `change` method:

```ruby
add_column :accounts, :two_factor_enabled, :boolean, null: false, default: false
```

Then migrate:

```sh
bin/rails db:migrate
```

The feature migrations add verification/MFA nonces, verification version, timestamps, and attempt counters to `phones`. The account flag stores whether MFA is required; credential flags store which factors are enabled.

## Configure the models and delivery

```ruby
# app/models/phone.rb
class Phone < ApplicationRecord
  include Vouch::Verifiable
  include Vouch::TwoFactorable

  belongs_to :account
  self.verifiable_subject_attribute = :e164

  def deliver_verification_code(code)
    SmsService.deliver(e164, "Your verification code is #{code}")
  end

  def deliver_two_factor_code(code)
    SmsService.deliver(e164, "Your sign-in code is #{code}")
  end
end
```

`SmsService` is an example of your application's delivery adapter. Implement it using your SMS provider. Add phone normalization and validation appropriate to your application.

Add the feature and association to the existing account model:

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :two_factorable
  has_many :phones, dependent: :destroy
end
```

Retain the account's existing password and validation configuration. Vouch discovers the phone association through its credential concerns; no table named `two_factor_credentials` is required for this example.

## Add sign-in challenge routes

Add `auth.two_factor` inside the account scope:

```ruby
auth.scope :account, model: "Account" do
  auth.sessions
  auth.registrations
  auth.two_factor
end
```

The generator creates `Accounts::TwoFactorChallengeController` and its challenge views. It does not generate enrollment behavior: the application decides permitted credential types, fields, and enrollment protocol. The route declaration also exposes credential-management endpoints; supply `Accounts::TwoFactorCredentialsController` and its views before using those endpoints.

The [controller reference](controllers.md#route-reference) lists challenge and credential-management URLs.

## Build the enrollment flow

Enrollment belongs in authenticated application pages. Build the credential through `current_account.phones`, permit only the intended fields, and look up subsequent requests through that same association.

For example, after saving a phone:

```ruby
result = phone.start_verification!
session[:phone_verification_token] = result.token if result.ok?
```

When the person submits the code:

```ruby
result = phone.complete_verification!(params[:code],
  token: session[:phone_verification_token])

if result.ok?
  phone.enable_two_factor!
  current_account.enable_two_factor!
  session.delete(:phone_verification_token)
end
```

These snippets illustrate the calls inside your enrollment actions; they are not complete controllers. Handle invalid, expired, locked, and cancelled results in the form, scope the phone lookup to the authenticated account, and rate-limit enrollment requests. Use per-credential session keys if the application supports concurrent enrollments.

## Sign-in behavior

When the account requires MFA, a valid password redirects to the challenge list. Choosing a factor issues its challenge; submitting its code completes account authentication only after successful verification. Any requested membership continuation then resumes.

`challenge!` returns a result containing the challenge token. `verify_challenge(code, token:)` reports success, invalid proof, lockout, or cancellation. Disabled or unverified credentials cannot satisfy MFA.

Account `enable_two_factor!` requires a usable verified, enabled, unlocked credential. Enabling a credential alone does not enable the account preference. Removing or disabling the final usable factor locks the account by default; applications can customize the last-factor policy.

## Other credential types and security contracts

TOTP requires an optional `rotp` dependency and application enrollment/QR presentation. TOTP and other factors may override challenge methods while preserving eligibility, lockout, and replay protection. Use the optional [credential adapter test contract](credential-adapter-contract.md) for custom implementations.

Verification, magic-link sign-in, and MFA have separate nonces. A new challenge retires the previous challenge. Persisted consumption is single-use and locked against concurrent acceptance. Subject changes invalidate old proofs, including changing a recipient away and back.

If adding `Vouch::MagicLinkable`, generate its separate schema and implement `deliver_sign_in_code`; the phone example above does not enable that feature. Missing delivery implementations raise rather than report successful delivery. See [passwords and recovery](passwords-and-recovery.md) for backup and account recovery codes.
