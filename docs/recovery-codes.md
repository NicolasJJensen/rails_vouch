# Recovery codes

A recovery code is a single-use alternative to an MFA challenge. When sign-in reaches an MFA challenge, the person chooses **Use a recovery code** on that page. A valid code completes that pending sign-in and is permanently invalidated.

You can attach a set to an account, a particular MFA credential, or both:

| Owner | Use |
| --- | --- |
| Account | Recover access independently of any particular phone, email address or authenticator |
| Credential | Replace the challenge for that specific phone, email address or authenticator |

Both use the same hashed-storage and single-use implementation. Replacing a set invalidates old codes for that owner only.

## Contents

- [Account-owned codes](#account-owned-codes)
- [Credential-owned codes](#credential-owned-codes)
- [Choose storage](#choose-storage)
- [Code format and results](#code-format-and-results)
- [Generate and replace a set](#generate-and-replace-a-set)
- [Sign in with a code](#sign-in-with-a-code)
- [Routes and customization](#routes-and-customization)
- [Organisation requirements](#organisation-requirements)

## Account-owned codes

After installing [MFA](mfa.md), add recovery codes to its account:

```sh
bin/rails generate vouch:recovery_codes User
bin/rails db:migrate
```

The generator adds:

- Recovery-code support and attempt-tracking columns to `User`.
- A `UserRecoveryCode` model and `user_recovery_codes` table.
- `User#recovery_codes` and `recovery_codes_from :recovery_codes`.
- A recovery-code settings controller and view, plus the MFA recovery form.

Its migrations add:

```ruby
change_table :users do |t|
  t.bigint :recovery_attempts, default: 0, null: false
  t.datetime :recovery_locked_at
end

create_table :user_recovery_codes do |t|
  t.references :user, null: false, foreign_key: true
  t.string :code_digest, null: false
  t.datetime :used_at, index: true
  t.timestamps
end
```

Only hashes are stored; plaintext codes are returned when a set is generated.

For a **multi-tenant application**, use the model that holds sign-in credentials, such as `Account`:

```sh
bin/rails generate vouch:recovery_codes Account
```

This adds the attempt columns to `accounts` and creates `account_recovery_codes` with an `account_id` reference. The other code columns are the same as above.

## Credential-owned codes

To add a set to each `Phone` belonging to `User`:

```sh
bin/rails generate vouch:recovery_codes Phone --owner User
bin/rails db:migrate
```

The migration creates:

```ruby
create_table :phone_recovery_codes do |t|
  t.references :phone, null: false, foreign_key: true
  t.string :code_digest, null: false
  t.datetime :used_at, index: true
  t.timestamps
end
```

The generator adds `PhoneRecoveryCode`, `Phone#recovery_codes` and `recovery_codes_from :recovery_codes`. The same setup works for other `TwoFactorable` credentials, including email and authenticator models.

Vouch verifies that the selected credential belongs to the pending or signed-in account. A credential-specific code cannot restore a credential that has been disabled, locked or had its verification cleared. Account-owned recovery codes remain independent of a device's state.

## Choose storage

> Compatible existing storage is reused. If its required indexes, non-null columns or concrete foreign key are missing, the generator adds a repair migration. It does not rewrite existing rows: reconcile null values or orphaned rows before running that migration. A conflicting owner relationship is rejected before new artifacts are written.

The default creates a separate table for each owner model. Account-owned and credential-owned codes can instead use one shared table:

```sh
bin/rails generate vouch:recovery_codes User --polymorphic
bin/rails generate vouch:recovery_codes Phone --owner User --polymorphic
```

Both commands use this `RecoveryCode` model and migration. A compatible existing table or pending migration is reused:

```ruby
create_table :recovery_codes do |t|
  t.references :recoverable, polymorphic: true, null: false
  t.string :code_digest, null: false
  t.datetime :used_at, index: true
  t.timestamps
end
```

```ruby
# app/models/recovery_code.rb
class RecoveryCode < ApplicationRecord
  belongs_to :recoverable, polymorphic: true
end

# app/models/phone.rb
class Phone < ApplicationRecord
  include Vouch::BackupCodable

  has_many :recovery_codes, as: :recoverable, dependent: :destroy
  recovery_codes_from :recovery_codes
end
```

For an existing custom code model, select its direct Rails association with `recovery_codes_from`. The code table must have `code_digest` and `used_at`, and its owner columns must identify that owner.

- Concrete storage supports custom and composite owner keys, with corresponding columns and a database foreign key.
- Shared polymorphic storage requires single-column owner keys with compatible database types. A bigint owner and a UUID owner cannot share the same `recoverable_id` column.

> `--polymorphic` rejects every composite-key owner, including owners with matching composite-key shapes. Use concrete tables for those owners; Vouch does not supply a serialized-key storage adapter.

## Code format and results

Account and credential recovery codes use the same format, such as `ABCD-EFGH`. Spaces, hyphens and letter case do not affect entry: `abcd efgh` matches that code. Every failed submission counts once, including a blank value. Trying an ordinary MFA code does not spend a second attempt on its recovery-code lookup.

Configure generation and the low-count reminder together:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.recovery_codes.code_count = 10
  config.recovery_codes.code_length = 8
  config.recovery_codes.low_threshold = 3
end
```

`recovery_codes_low?` returns true when fewer than `low_threshold` unused codes remain. Use it to display a reminder; it does not generate replacements.

Both owners expose normal methods that return a `Vouch::Result`, and bang methods that raise `Vouch::OperationFailed` for an unsuccessful result. The exception's `result` contains the same failure information. Unexpected exceptions propagate.

## Generate and replace a set

The generated `RecoveryCodesController` and its `show` view provide a settings page:

```erb
<%= link_to "Recovery codes", user_recovery_codes_path %>
```

For a credential-owned set, include the selected credential:

```erb
<%= link_to "Phone recovery codes", user_recovery_codes_path(
  recovery_owner_type: "Phone",
  recovery_owner_id: phone.id
) %>
```

The page shows the remaining count and a button to generate a set. Generation displays the plaintext codes once. Subsequent visits show the remaining count, not the codes.

Replacing a set deletes every previous hash and saves the replacement hashes in one transaction. Old paper or digital copies stop working immediately after the replacement commits.

Override the generated action to authorize the selected record or customize its response. `@recovery_owner` is set before the action runs:

```ruby
# app/controllers/users/recovery_codes_controller.rb
class Users::RecoveryCodesController < Vouch::RecoveryCodesController
  def create
    # Check permission to replace @recovery_owner's recovery codes.
    status = super
    unless status == :ok
      redirect_to security_settings_path, alert: "Your recovery codes were not changed."
    end
  end
end
```

`super` returns a status such as `:ok`, `:invalid` or `:cancelled`. Successful generation sets `@recovery_codes` to the plaintext codes and `@remaining_recovery_codes` to their count before control returns to your action. Use those variables to supply a different presentation, including JSON or Turbo.

If your action does not respond, Vouch's `default_render` displays the codes after it finishes, or redisplays the settings page with the storage error. Errors on an affected code record remain available through `@operation_error.record` when the underlying exception supplies that record. An owner type and ID must match an allowed record belonging to the signed-in account. Vouch does not resolve arbitrary Ruby classes from the submitted type.

For composite primary keys, pass `Vouch::RecordKey.to_param(phone)` instead of `phone.id`. Ordinary scalar IDs need no encoding helper.

## Sign in with a code

The generated MFA pages provide the recovery option. When both kinds are enabled, the recovery form identifies which set to use.

1. The person completes the first sign-in step, such as password or provider authentication.
2. They choose **Use a recovery code** at the MFA prompt.
3. Vouch compares the submitted code with unused hashes for the selected owner.
4. Vouch atomically consumes a matching code and completes sign-in.
5. A warning explains that a recovery code was used and directs them to manage their factors.

A recovery code cannot start a login on its own. It completes the pending authentication and creates a normal authenticated session; it does not enable a persistent “remember me” session.

Someone already signed in can also use a recovery code when [confirming a sensitive action](authentication-policy.md#confirm-identity-before-a-sensitive-action) or [providing another MFA proof](mfa.md#request-another-mfa-proof). That keeps their existing session and records the additional recovery proof.

The generated credential-management page lets the person enroll and verify a replacement factor before deleting the lost device:

```erb
<%= link_to "Manage authentication devices", user_two_factor_credentials_path %>
```

## Routes and customization

| Request | Helper | Action |
| --- | --- | --- |
| `GET /users/recovery` | `user_recovery_two_factor_challenge_path` | `Users::TwoFactorChallengeController#recovery` |
| `POST /users/recovery` | `user_consume_recovery_two_factor_challenge_path` | `Users::TwoFactorChallengeController#consume_recovery` |
| `GET /users/recovery_codes` | `user_recovery_codes_path` | `Users::RecoveryCodesController#show` |
| `POST /users/recovery_codes` | `user_recovery_codes_path` | `Users::RecoveryCodesController#create` |

`auth.two_factor_challenges` supplies the recovery challenge and code-submission routes. `auth.recovery_codes` supplies the settings page and set-generation route. The recovery-code generator adds both declarations when they are missing:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  Vouch.routes(self) do |auth|
    auth.scope model: "User" do
      auth.sessions
      auth.two_factor_challenges
      auth.recovery_codes
    end
  end
end
```

Edit the generated views for presentation. Recovery completes through the ordinary sign-in lifecycle, so the same [redirects](controllers.md#redirects) and [sign-in hooks](sessions-and-hooks.md#lifecycle-hooks) apply.

## Organisation requirements

The session records recovery-code authentication and its owner. It never describes the code as proof that the associated authenticator was used.

Your application can decide whether recovery proof satisfies its workspace access rules. Vouch identifies it as `recovery_code` in the [MFA evidence collection](authentication-policy.md#mfa-evidence-and-application-permissions); it does not claim that the lost authenticator was used.
