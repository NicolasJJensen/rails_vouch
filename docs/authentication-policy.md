# Authentication policy

This guide explains how Vouch completes authentication after credentials, OAuth, or host-implemented magic links. Start with the [README](../README.md), then see [controllers](controllers.md), [OAuth](oauth.md), and [verification and MFA](verification-and-mfa.md).

## Restrict eligible memberships

A membership controller can restrict its account's eligible records:

```ruby
class Users::SessionsController < Vouch::MembershipSessionsController
  auth_scope :user

  private

  def candidate_identities_for(account)
    super.where(active: true)
  end
end
```

This example assumes an application-defined `active` column. Keep the account ownership constraint supplied by `super`. The selection form snapshots eligible IDs and submission reapplies the current policy. A scope name such as `admin` does not grant permissions.

Account authentication completes required MFA before publishing the account session. Linked membership selection then uses that authenticated account, without asking for its password or repeating account MFA.

## Completion contract

The Warden strategy name `:password` is reserved; custom strategies must use another name. Password verification uses `store: false`, and controllers explicitly establish the authenticated identity.

`complete_sign_in` applies one policy to password, OAuth, and magic-link login. It returns `:signed_in`, `:needs_two_factor`, `:needs_selection`, `:no_identity`, or `:denied`. Locked accounts are rejected. Accounts with enabled MFA require a verified, enabled second factor. OAuth does not bypass local policy by default.

```ruby
Vouch.configure do |config|
  config.pending_authentication_ttl = 10.minutes
  config.oauth_mfa_providers = ["company_sso"]
  config.authentication_policy = "ApplicationAuthenticationPolicy"
end

class ApplicationAuthenticationPolicy < Vouch::AuthenticationPolicy
  def allowed?(account, method:, provider:, controller:)
    super && !account.suspended?
  end
end
```

List a provider in `oauth_mfa_providers` only when it supplies the required assurance. It exempts that provider from local MFA, but not account locks.

## Lockout and revocation

Lockout blocks new authentication and leaves established sessions in place by default. To reject ordinary and pending-account Warden sessions on their next request:

```ruby
Vouch.configure { |config| config.lockable.invalidate_sessions_on_lockout = true }
```

Impersonation restoration already rejects locked operators. An established session rejected during a temporary lock may become usable again after the lock expires; hosts requiring permanent revocation should increment persisted `auth_session_version` when locking.

Pending authentication binds account identity, security fingerprint, time, and candidate identities. It expires independently of challenge tokens. Password changes invalidate pending flows, established sessions, and impersonation restoration automatically. Hosts can define `auth_session_version` and increment it after other security changes.

A verified magic-link proof may remain pending through selection or MFA. Revoking its credential does not revoke that flow automatically; increment `auth_session_version` in the same transaction when immediate revocation is required. Otherwise the configured TTL applies.

`candidate_identities_for(account)` remains an upper bound through MFA and selection. Selection reapplies the current controller's candidate policy. Put shared, changing policy in a common auth-controller concern.
