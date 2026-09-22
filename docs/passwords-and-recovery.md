# Passwords and recovery

This guide covers password reset, history, backup codes, and signed links. See the [README](../README.md), [verification and MFA](verification-and-mfa.md), and [persistence](persistence.md).

## Password reset

Reset tokens are random and only their SHA-256 digest is stored:

```ruby
token_result = account.generate_password_reset_token!
token = token_result.value
account = Account.find_by_auth_password_reset_token(token)
account.reset_password_with_token!(token, password: new_password,
  password_confirmation: confirmation)
```

Use Vouch's lookup, not Rails' native `find_by_password_reset_token`. Blank or non-String tokens return `nil` from lookup and `Result.invalid` from consumption. Consumption locks and rechecks the token while changing the password and clearing reset state; validation failure preserves it. Any persisted password change clears outstanding reset state, including changes outside the reset controller. Password history rejects the current and configured archived passwords.

## Recovery codes and signed links

Recoverable stores account-level BCrypt-hashed codes. BackupCodable stores per-credential codes. Generate plaintext once, display it, and store only digests. Consumption and regeneration serialize on the owner. When a credential has both `TwoFactorable` and `BackupCodable`, backup codes are tried as alternate `verify_challenge` proofs and successful use clears failed-factor state atomically. This does not make backup codes account-level recovery codes. Custom flows that bypass `verify_challenge` call `consume_backup_code!` and retain authorization and rate-limit policy. Recovery randomness uses `SecureRandom`; model `recoverable:` options override global defaults.

Signed `TokenVerifiable` links bind to an atomically rotated nonce. Generate them only from persisted records; drafts and destroyed records raise. Configure mutable recipients explicitly:

```ruby
class EmailConfirmation < ApplicationRecord
  include Vouch::TokenVerifiable::Concern
  self.token_subject_attribute = :email_address
end
```

Tokens bind to that attribute. Saved recipient changes clear verification and rotate the nonce, including A to B and back to A. Without the option, links retain record-bound semantics. Hosts own delivery, route authorization, and equivalent invalidation for callback-bypassing writes.
