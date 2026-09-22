# Impersonation

Impersonation is host-authorized and session-backed. This guide extends the [README](../README.md); see [authentication policy](authentication-policy.md) and [sessions and hooks](sessions-and-hooks.md).

## Setup

Add impersonation to an existing scope and generate its host-owned controller:

```sh
bin/rails g vouch:impersonation users
bin/rails g vouch:impersonation portal --auth-scope user
```

The generator adds `auth.impersonation` to the unique existing `auth.scope :user` block and writes `Users::ImpersonationsController`. It denies access until the host replaces `authorize_impersonation!` with its authorization rule. The gem does not define an administrator role.

## Session and restoration rules

Session rotation preserves the original identity explicitly, and stop restores it across requests. Switching targets keeps the same original operator; stop endpoints return to that operator without a nested stack. A locked operator or changed password fingerprint prevents restoration. Hosts can increment `auth_session_version` to revoke restoration after other security changes.
