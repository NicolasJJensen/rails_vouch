# Model mapping and reflection

Mappings connect account, identity, tenant, and feature associations. The baseline examples are in the [README](../README.md); see [OAuth](oauth.md), [controllers](controllers.md), and [warden](warden.md) for related integration.

## Explicit associations

Only enabled features undergo concern discovery. Restrict discovery when needed:

```ruby
auth.scope :user, account: "Account", identity: "User",
  associations: {two_factorable: [:phones, :authenticators]}
```

Account, identity, and tenant relationships use one flat hash when discovery is ambiguous:

```ruby
auth.scope :member, account: "Owner", identity: "Membership", tenant: "Workspace",
  path: "members", as: :member,
  associations: {account_identities: :memberships, identity_account: :owner,
    identity_tenant: :workspace, tenant_identities: :memberships} do
  auth.sessions(path_names: {sign_in: "login"}, controller: "members/sessions")
end
```

Omit overrides when exactly one matching association exists. Polymorphic associations are excluded from automatic relationship discovery. Paths, route helpers, selected features, and controller overrides remain independent of association names.

## OAuth and password-history mapping

OAuth identity ownership resolves separately from membership ownership. The resolver uses the account's OAuth association and its inverse metadata. If an OAuth row belongs to `owner` while membership belongs to another account association, configure `oauth_account: :owner`; this does not change `identity_account`. Polymorphic OAuth ownership can retain `belongs_to :account, polymorphic: true` and `has_many :oauth_identities, as: :account`, with `omniauthable: :oauth_identities` and `oauth_account: :account` when ambiguous.

The generator covers the ordinary one-owner relationship. Keep legacy, nonstandard, or polymorphic ownership explicit in the host. For an OAuth model whose account owner is named `owner`, configure both the account collection and inverse owner:

```ruby
class Account < ApplicationRecord
  has_many :oauth_connections, class_name: "OAuthConnection", foreign_key: :owner_id
end

class OAuthConnection < ApplicationRecord
  include Vouch::OAuthIdentity::Concern
  belongs_to :owner, class_name: "Account"
end

auth.scope :user, account: "Account", identity: "User",
  associations: {
    account_identities: :users,
    identity_account: :account,
    omniauthable: :oauth_connections,
    oauth_account: :owner
  } do
  auth.sessions
  auth.oauth_callbacks
end
```

Password-history association selection belongs on the account model:

```ruby
class Owner < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password
  has_many :password_archives, class_name: "PasswordArchive", foreign_key: :owner_id
  authenticates_with :password_trackable,
    password_trackable: {association: :password_archives}
end
```

The archive includes `Vouch::PasswordArchive::Concern`. Omit the option when exactly one association is discoverable. Every scope for that account uses the same selection; move conflicting route-level configuration to the model.

Password-history correctness across concurrent updates belongs to the host's write policy. If multiple requests can change a password, lock and reload the account before assigning the new password:

```ruby
account.with_lock do
  account.update!(password: new_password, password_confirmation: new_password)
end
```

Apply the same policy to every host password-writing path. A lock acquired after assigning a password on a stale object does not refresh the history used by that assignment. Database constraints and any optimistic locking policy remain host responsibilities.

Password validation also works without any registered routes. Without overrides, the gem discovers feature associations by concern inclusion. Ambiguous single-association features raise a configuration error, and explicit associations are validated. Resolver names and model references resolve through current Rails classes after reloading. The gem does not change global OTP/SMS inflections.
