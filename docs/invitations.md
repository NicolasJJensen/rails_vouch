# Invitations

Invitation state crosses account registration and tenant membership. This guide extends the [README](../README.md); see [impersonation](impersonation.md), [controllers](controllers.md), and [persistence](persistence.md).

## Registration contract

Accounts use persisted `registration_required` to distinguish placeholders from registered accounts. Invitations also record `invitation_registration_required`; registration requires both flags. New-account acceptance completes the invited identity in its original tenant. Existing-account invitations require authentication and cannot change that account's password. Expired or revoked invitations fail even with stale browser state.

Add `registration_required` as a non-null boolean defaulting to `false` when upgrading. Backfill retained pending placeholders to `true`; registered accounts remain `false`. New invitations must set it only for new placeholder accounts. `build_invited_identity(identifier)` returns a persisted mapped account and must preserve host identifier normalization and validation.

## Authorization and associations

Creation is denied until the host defines `authorize_invitation!`; the hook may return only when the current identity may invite. The default revocation relation covers pending invitations issued by the current identity, within its tenant where applicable. Override `revocable_invitations` for host policy.

Add `Vouch::Invitable::Concern` to the identity model and declare ownership associations:

```ruby
belongs_to :inviter, class_name: "YourIdentity", optional: true
has_many :invitees, class_name: "YourIdentity", foreign_key: :inviter_id, dependent: :nullify
```

`IdentityModel.invite!` returns `Vouch::Result.ok(invitee)`; use `.value` for the persisted invitation. Cancellation raises `Vouch::Persistence::Cancelled`.

Successful invited signup clears the account flag in the same transaction as password update and acceptance. Hosts with additional onboarding state can override `registration_required?` and `complete_registration!`; completion must persist in the current transaction.

Revocation removes a pending split-model identity or clears a single-model token. It does not delete host accounts. `around_invitation_revocation` can remove disposable placeholders inside the invitation transaction; account retention and cross-scope references remain host policy. `accept_invitation!` locks and reloads before checking token and expiry, so stale instances cannot accept replaced or already-used invitations.

The revocation hook runs inside the invitation transaction. If account destruction is cancelled, the invitation revocation rolls back as well.

## Generator examples

When identity model and route scope differ:

```sh
bin/rails g vouch:invitations Admin::Member Account --auth-scope user --controller-path users
```

For a single model:

```sh
bin/rails g vouch:invitations members --single-model --auth-scope member --controller-path members
```

The generated single-model controller is fail-closed until the host replaces `authorize_invitation!` and the illustrative email `build_invited_identity`. Replace both with authorization, normalization, validation, and required attributes before enabling `auth.invitations`.

For existing installations, add `registration_required` to the account table as a non-null boolean with a default of `false`. Set it to `true` for accounts that still await invited registration, including retained placeholders without an invitation. Existing registered accounts must remain `false`. For new installations, the invitations generator supplies the migration once per account table. Hosts using another identifier should override `build_invited_identity(identifier)` and keep their own lookup and validation rules.
