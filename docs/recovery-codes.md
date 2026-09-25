# Recovery codes

A recovery code is a single-use alternative to an MFA challenge. The person first signs in with their username/email and password, then chooses **Use a recovery code** on the MFA page. A valid code completes that pending sign-in and is permanently invalidated.

You can attach a set to an account, a particular MFA credential, or both:

| Owner | Use |
| --- | --- |
| Account | Recover access independently of any particular phone, email address or authenticator |
| Credential | Replace the challenge for that specific phone, email address or authenticator |

Both use the same hashed-storage and single-use implementation. Replacing a set invalidates old codes for that owner only.

## Account-owned codes

After installing [MFA](verification-and-mfa.md), add recovery codes to its account:

```sh
bin/rails generate vouch:recovery_codes User
bin/rails db:migrate
```

The migrations add attempt tracking to `users` and create the recovery-code table:

```ruby
add_column :users, :recovery_attempts, :bigint, default: 0, null: false
add_column :users, :recovery_locked_at, :datetime

create_table :vouch_recovery_codes do |t|
  t.string :recoverable_type, null: false
  t.bigint :recoverable_id, null: false
  t.string :code_digest, null: false
  t.datetime :used_at
  t.timestamps
end
add_index :vouch_recovery_codes, [:recoverable_type, :recoverable_id], name: "index_vouch_recovery_codes_on_recoverable"
```

The shared table identifies its owner with `recoverable_type` and `recoverable_id`. Only hashes are stored; Vouch returns plaintext codes when a set is generated.

For a **multi-tenant application**, use the credentials account:

```sh
bin/rails generate vouch:recovery_codes Account
```

The attempt columns go on `accounts`; the shared code table remains the same. Its pages use `/accounts` and `account_` route prefixes.

## Credential-owned codes

To add a set to each `Phone` belonging to `User`:

```sh
bin/rails generate vouch:recovery_codes Phone --owner User
bin/rails db:migrate
```

The migration creates:

```ruby
create_table :phone_backup_codes do |t|
  t.bigint :phone_id, null: false
  t.string :code_digest, null: false
  t.datetime :used_at
  t.timestamps
end
add_index :phone_backup_codes, :used_at
add_index :phone_backup_codes, :phone_id
add_foreign_key :phone_backup_codes, :phones
```

The internal association is named `backup_codes`; the public feature and its model methods use recovery-code terminology. The same setup works for other `TwoFactorable` credentials, including email and authenticator models.

Vouch verifies that the selected credential belongs to the pending or signed-in account. A credential-specific code cannot restore a credential that has been disabled, locked or had its verification cleared. Account-owned recovery codes remain independent of a device's state.

## Generate and replace a set

The generated `RecoveryCodesController` and its `show` view provide a settings page:

```erb
<%= link_to "Recovery codes", user_recovery_codes_path %>
```

For a credential-owned set, include the selected credential:

```erb
<%= link_to "Phone recovery codes", user_recovery_codes_path(
  recovery_owner_type: "credential",
  recovery_owner_id: "#{phone.model_name.singular}-#{Vouch::RecordKey.to_param(phone)}"
) %>
```

The page shows the remaining count and a button to generate a set. Generation displays the plaintext codes once. Subsequent visits show the remaining count, not the codes.

Replacing a set deletes every previous hash and saves the replacement hashes in one transaction. Old paper or digital copies stop working immediately after the replacement commits.

For your own settings controller, the same operation is:

```ruby
result = current_user.generate_recovery_codes!
@recovery_codes = result.value if result.ok?
```

Use `phone.generate_recovery_codes!` for a phone-owned set. Both owners expose `recovery_codes_remaining` and `recovery_codes_low?`.

## Sign in with a code

The generated MFA pages provide the recovery option. When both kinds are enabled, the recovery form identifies which set to use.

1. The person supplies their password at the normal sign-in page.
2. They choose **Use a recovery code** at the MFA prompt.
3. Vouch compares the submitted code with unused hashes for the selected owner.
4. Vouch atomically consumes a matching code and completes sign-in.
5. A warning explains that a recovery code was used and directs them to manage their factors.

A recovery code cannot start a login without the pending first-factor authentication. It creates a normal authenticated session; it does not enable a persistent “remember me” session.

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

These routes are included by `auth.two_factor`. Edit the generated views for presentation. Recovery completes through the ordinary sign-in lifecycle, so the same [redirects](controllers.md#redirects) and [sign-in hooks](sessions-and-hooks.md#lifecycle-hooks) apply.

## Organisation requirements

The session records recovery-code authentication and its owner. It never describes the code as proof that the associated authenticator was used.

An organisation can reject recovery-code authentication even when the account permits it. The account remains available for factor management, while organisation access requires an accepted factor. See [membership MFA requirements](authentication-policy.md#mfa-required-by-an-organisation).
