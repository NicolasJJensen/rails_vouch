# Vouch

Vouch is a Rails authentication engine built on Warden and ActiveRecord. Accounts own credentials. Identities represent application memberships, optionally within tenants. A single-model scope can use one model for both roles.

## Installation

Add `gem "rails_vouch"` to the host Gemfile. Run `bundle install`, then:

```sh
bin/rails generate vouch:install
```

If the install generator reports that `Vouch.routes(self)` should be
pasted into `config/routes.rb`, paste that scaffold before running the scope
generator:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
bin/rails db:migrate
```

To scaffold the optional password-reset or two-factor controllers and views as
well as their model migration, pass the authentication route scope and the
controller namespace together. The model argument still selects the table to
extend; it does not choose a route scope.

```sh
bin/rails g vouch:password_resetable Account --auth-scope user --controller-path users
bin/rails g vouch:two_factorable Totp --auth-scope user --controller-path users
```

These commands generate subclasses with `auth_scope :user` and views under
`app/views/users`. Add the matching `auth.passwords` or `auth.two_factor`
route yourself. The two-factor command generates only sign-in challenge UI;
credential enrollment stays host-owned because each credential type needs its
own permitted fields and enrollment protocol. Omit both options for
migration-only generation.

The scope generator wires sessions, registrations, and (for split-model scopes)
identity selection, including plain accessible host views. Replace those views
with the application's UI and validations. Generate optional features separately
and add their route methods inside the scope block after adding the corresponding
concerns, models, and migrations.

When `:two_factorable` is enabled, add an account-level non-null boolean named
`two_factor_enabled` (default `false`) to each mapped account table. Existing
hosts must backfill it from any credential with a previously enabled
`two_factor_enabled_at`, including records that are now unverified, before
turning on the feature. The scope generator cannot infer a host's account table
or credential associations, so inspect and adapt this migration manually.

For a single model, use `vouch:scope members Member --single-model`. Generator primary-key options support UUID hosts. Inspect generated migrations before applying them. PostgreSQL is the tested database. The gem requires Ruby >= 3.2 and Rails >= 8, < 9; individual Rails versions impose their own Ruby minimums.

Namespaced model arguments are supported, for example `Admin::Account` and `Admin::Phone`. Feature generators share model naming rules with the scope generator. They generate namespace paths and explicit table names where Rails needs them. Already loaded models supply their table metadata. Generators do not trigger model autoloading before migrations. Check migrations for custom tables when the model is not loaded.

Core runtime dependencies are Warden, BCrypt, active_hooks, and otp_courier. OmniAuth and its provider gems are opt-in: add them only when using OAuth. ROTP is opt-in in the same way: add it only when implementing TOTP. QR rendering is a host responsibility and does not require a specific QR library.

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :lockable, :password_resetable, :password_trackable,
    :two_factorable, :omniauthable, :recoverable
  has_secure_password

  has_many :users
  has_many :oauth_identities, class_name: "OauthIdentity",
    foreign_key: :account_id, dependent: :destroy
  has_many :two_factor_credentials
  has_many :password_archives
end
```

Enable only installed features and add their generated columns/models. Host models own identifier normalization, database uniqueness constraints, password validation, associations, and outbound delivery.

For a non-email login identifier, keep lookup, account creation, and the generated host views in the host. The baseline scope generator uses `email_address`; replace that field consistently in the schema, model, registration controller, and both generated forms.

First, add the identifier column and make `email_address` optional if login replaces it. Adapt the table name if the mapped account uses a custom table:

```ruby
# db/migrate/..._add_login_to_accounts.rb
class AddLoginToAccounts < ActiveRecord::Migration[8.0]
  def change
    change_column_null :accounts, :email_address, true
    add_column :accounts, :login, :string, null: false
    add_index :accounts, :login, unique: true
  end
end
```

Normalize the value before validation and keep the model validation aligned with the database constraint:

```ruby
class Account < ApplicationRecord
  normalizes :login, with: ->(value) { value.strip.downcase }
  validates :login, presence: true, uniqueness: true
end
```

Register a resolver. A resolver receives the submitted top-level session params and the mapped account class:

```ruby
class LoginResolver < Vouch::LoginResolver::Base
  def valid?(params)
    params[:login].present?
  end

  def resolve!(params, account_class)
    login = params[:login].to_s.strip.downcase
    account = account_class.find_by(login: login)
    account ? success!(account) : fail!
  end
end

# Load a host resolver before registering it from an initializer. Keep the
# class in an autoloaded host file such as app/models/login_resolver.rb.
require Rails.root.join("app/models/login_resolver").to_s

Vouch.configure do |config|
  config.register_login_resolver LoginResolver
end
```

Replace the generated registrations controller's `account_params`; the account attributes are nested under the mapping's account parameter key. Keep password fields permitted and replace `:email_address` with `:login`:

```ruby
# app/controllers/users/registrations_controller.rb
class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def account_params
    params.require(auth_mapping.account_param_key).permit(:login, :password, :password_confirmation)
  end
end
```

Then edit the generated host-owned views. In `app/views/users/sessions/new.html.erb`, replace the email field with the top-level `login` parameter used by the resolver:

```erb
<%= label_tag :login %>
<%= text_field_tag :login, params[:login], autocomplete: "username", required: true %>
```

In `app/views/users/registrations/new.html.erb`, replace the account email field with the nested `login` attribute accepted by `account_params`:

```erb
<%= form.label :login %>
<%= form.text_field :login, value: @account.login, autocomplete: "username", required: true %>
```

The same principle applies to any custom registration or OAuth completion view: submit `login` under the account parameter key and permit it in the host controller. Invitation creation uses a separate host controller hook; `build_invited_identity(identifier)` must normalize the identifier, find or create a persisted account, and set `registration_required: true` only on a new placeholder. These hooks do not change tenant assignment or the generated registration identity. The account schema and any tenant fields remain host-owned.

After the baseline install, verify the generated public endpoints with `GET /users/sign_in` and `GET /users/sign_up`. `GET /users/password/new` exists only when password routes are enabled. Optional features require the matching migration and model concern, the host association, the feature controller and route, and any host delivery implementation and views. For example, a two-factor credential needs the generated credential columns plus `Verifiable`/`TwoFactorable`, a `has_many` association on the account, `two_factor_challenge` and credential routes/controllers, and a `deliver_two_factor_code` implementation; the optional generator can supply challenge views, while the host supplies enrollment views. Verification and magic-link credentials follow the same migration, concern, association, controller/route, delivery, and view pattern.

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, account: "Account", identity: "User", tenant: "Organisation" do
    auth.sessions
    auth.registrations
    auth.user_selection
  end
end
```

After loading host models, `Vouch.verify!` can be used in a deployment
or boot check to re-run account, identity, tenant, OAuth, and credential
association validation without rebuilding the route set.

The equivalent Rails task is:

```sh
bin/rails vouch:verify
```

It reports all mapping and feature contract failures together. It does not
alter schema or run migrations.

Token-verifiable records are standalone host credentials. Their schema is
host-owned and has no account mapping contract from which this boot verifier
can discover every such model; hosts should validate those columns in their
credential checks before enabling token flows.

The engine development dummy app exposes the same task under Rails' generated
`app:vouch:verify` namespace.

A block selects routes explicitly:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :member, model: "Member" do
    auth.sessions
    auth.registrations
    auth.passwords
  end
end
```

Every scope requires a block. Select the baseline session, registration, and
split-model identity-selection routes explicitly, then add optional route
methods after installing their feature's model support, required associations,
delivery hooks, and any host-owned controller or view.

## Controller integration

Auth controllers inherit `Vouch::BaseController`, which supplies scope-aware authentication guards. The configured parent defaults to `ApplicationController`. A normal Rails parent does not need custom authentication macros.

```ruby
Vouch.configure do |config|
  config.parent_controller = "ApplicationController"
  config.authentication_callbacks = [:authenticate_user!]
end
```

Declare `authentication_callbacks` only if the host parent already installs authentication filters. Public auth actions skip those filters. Protected actions retain them. Configure the parent before loading auth controllers.

Subclass `Vouch::SessionsController`, `RegistrationsController`, or other feature controllers to customize behavior. Use `auth_scope :member` when scope inference from the controller namespace is unsuitable. Auth code uses `current_identity` and `current_account`, independent of a host's `current_user` helper. Override redirect methods when the host does not use `root_path`. For OAuth continuation customization, override the protected `serialize_oauth` and `parse_oauth` pair on the concrete OAuth controller, or on a host controller superclass that inherits `Vouch::BaseController`; the configured parent controller is an ancestor of `Vouch::BaseController`, so it cannot override these included helpers. Authentication completion and session continuation helpers are internal wiring.

For a small custom-scope override, keep the feature controller thin and select it explicitly in the route block:

```ruby
class Members::PasswordsController < Vouch::PasswordsController
  auth_scope :member
end

Vouch.routes(self) do |auth|
  auth.scope :member, model: "Member" do
    auth.sessions
    auth.registrations
    auth.passwords controller: "members/passwords"
  end
end
```

Optional routes require both the feature's model support and the matching
controller. Password-reset and two-factor generators create a controller and
views when passed both UI options. The invitations generator creates its
host-owned controller and form. Hosts add the route, delivery and authorization
policy, associations, and any ungenerated controller or view, including MFA
enrollment.

Feature setup follows one recipe: run the feature generator for the mapped
table, add the generated concern to the account or credential model, declare
the host association, migrate, add the feature route, configure any generated
controller and views, and provide the host delivery method. For example:

```sh
bin/rails g vouch:two_factorable users
bin/rails g vouch:verifiable phone_verifications
bin/rails g vouch:magic_linkable phone_verifications
bin/rails db:migrate
```

Then add `auth.two_factor` or the relevant feature route inside the explicit
scope block. `auth.two_factor` adds both the challenge and credential routes.
Credential models must provide
their delivery override (`deliver_two_factor_code`,
`deliver_verification_code`, or `deliver_sign_in_code`). Run
`bin/rails vouch:verify` after migrations and model wiring; it checks
the mapped columns, associations, concern targets, and delivery contracts.

| Route method | Controllers needed | Base controller |
| --- | --- | --- |
| `auth.passwords` | `PasswordsController` | `Vouch::PasswordsController` |
| `auth.two_factor` | `TwoFactorChallengeController`, `TwoFactorCredentialsController` | `Vouch::TwoFactorChallengeController`, `Vouch::TwoFactorCredentialsController` |
| `auth.oauth_callbacks` | `OmniAuthsController` | `Vouch::OmniAuthsController` |

Registration exposes `registration_tenant_attributes`, `registration_identity_attributes`, and `build_registration`. A tenant host must provide its tenant attributes. Configure custom identity-to-account associations with `associations: {identity_account: :owner}` in the mapping.

To customize a shipped controller in place, eject it into the host application:

```sh
bin/rails g vouch:eject members sessions
```

The generated controller keeps Vouch's runtime `auth_mapping` helpers and adapts its class declaration to the requested namespace. When the namespace and authentication scope differ, pass `--auth-scope` explicitly, for example `bin/rails g vouch:eject portal sessions --auth-scope user`; this emits `auth_scope :user`. The `--concrete` option remains as a deprecated compatibility alias for this same output; it no longer inlines mapping classes or associations. Use a host subclass when a small override is sufficient.

Forms use the account's `model_name.param_key`. For `Admin::Account`, the usual registration parameter is `admin_account`. Custom model names follow Rails form conventions.

## Authentication policy

The reserved Warden strategy name is `:password`. Custom strategies must use a different name. Password verification uses `store: false`; controllers explicitly establish the authenticated identity.

`complete_sign_in` applies one completion policy for password, OAuth, and host-implemented magic-link login. It returns `:signed_in`, `:needs_two_factor`, `:needs_selection`, `:no_identity`, or `:denied`.

Default policy rejects locked accounts. Accounts with enabled 2FA must complete a verified, enabled second factor. OAuth does not bypass local policy by default.

Lockout blocks new authentication by default but leaves established sessions in
place. To reject ordinary identity and pending-account Warden sessions on their
next request, opt in globally:

```ruby
Vouch.configure do |config|
  config.lockable.invalidate_sessions_on_lockout = true
end
```

This does not change impersonation restoration, which already rejects locked
operators. A temporary lock that expires may restore a session on a later
request; hosts that require permanent revocation should advance their
`auth_session_version` when they lock the account.

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

Only list a provider in `oauth_mfa_providers` when the host's provider integration ensures the required authentication assurance. The list exempts that OAuth provider from the local second-factor requirement; it does not exempt account locks.

Pending authentication binds to account identity, password/security fingerprint, time, and candidate identities. It expires independently of challenge tokens. Password changes invalidate pending flows. A host can define a persisted `auth_session_version` on its account model. Increment it to revoke pending authentication, established sessions, and impersonation restoration after other security changes. Password changes revoke all three automatically.

A verified magic-link proof can remain pending during identity selection or second-factor verification. Revoking its source credential does not automatically revoke that pending flow. If your policy requires immediate revocation, change the account's persisted `auth_session_version` in the same transaction as credential revocation. This also revokes established sessions. Otherwise, the pending flow expires at its configured TTL.

The candidate set from `candidate_identities_for(account)` remains an upper bound through 2FA and identity selection. Selection also reapplies the current controller's candidate policy. Put shared policy in a common auth-controller concern when it must reflect changing permissions across several controllers.

## OAuth routes

OAuth identities belong to the authentication account. They are not application
memberships: in a split-model scope, the membership still connects the account
to its tenant. Install OmniAuth and the provider strategy, then generate the
ordinary account-owned identity:

```sh
bundle add omniauth omniauth-github
bin/rails g vouch:omniauth accounts
bin/rails db:migrate
```

`accounts` is the default generator argument, and `Account` is accepted too.
The generator creates `OauthIdentity`, its `account_id` foreign key, and this
association on the owner model:

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :omniauthable

  has_many :oauth_identities, class_name: "OauthIdentity",
    foreign_key: :account_id, dependent: :destroy
end
```

For a single-model scope, target that model instead. The generated identity
then has `belongs_to :member`, while `Member` owns the matching collection:

```sh
bin/rails g vouch:scope members Member --single-model
bin/rails g vouch:omniauth members
bin/rails db:migrate
```

Add `authenticates_with :omniauthable` to `Member`, and enable the generated
association and callback route in the scope. The generator intentionally does
not add a provider, controller, or route because those are host policy.

```ruby
Vouch.routes(self) do |auth|
  auth.scope :member, model: "Member", associations: {omniauthable: :oauth_identities} do
    auth.sessions
    auth.registrations
    auth.oauth_callbacks
  end
end

class Members::OmniAuthsController < Vouch::OmniAuthsController
  auth_scope :member
end
```

For a split account/membership scope, generate the identity for the account,
not the membership. This remains true when the membership also has a tenant:

```sh
bin/rails g vouch:scope users Account:account User:identity Organisation:tenant
bin/rails g vouch:omniauth accounts
bin/rails db:migrate
```

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, account: "Account", identity: "User", tenant: "Organisation",
    associations: {
      account_identities: :users,
      identity_account: :account,
      identity_tenant: :organisation,
      tenant_identities: :users,
      omniauthable: :oauth_identities
    } do
      auth.sessions
      auth.registrations
      auth.user_selection
      auth.oauth_callbacks
    end
end

class Users::OmniAuthsController < Vouch::OmniAuthsController
  auth_scope :user
end
```

OAuth creation and linking use `Account#oauth_identities`; they do not create
or select an `Organisation`. Keep tenant selection and membership creation in
the registration policy, where the host has the required tenant context.

Default callback paths are scope-specific:

```text
/users/auth/:provider/callback
/users/auth/failure
/admins/auth/:provider/callback
/admins/auth/failure
```

Configure the OmniAuth middleware request/callback paths and provider redirect allowlists to match. Route generation does not configure provider credentials or disable OAuth state validation. Each callback must come through the configured provider middleware.

```ruby
Vouch.routes(self) do |auth|
  auth.scope :user, account: "Account", identity: "User" do
    auth.sessions
    auth.oauth_callbacks callback_methods: [:get, :post]
  end
end
```

Use `callback_path:` and `failure_path:` for explicit routes. Choose only methods required by the provider. Existing signed-in identities link a provider to their own account; they cannot switch accounts by linking a provider already owned elsewhere.

By default, an unknown OAuth callback creates the account, OAuth identity, and application identity immediately. A host can require its ordinary sign-up form first by overriding the protected `oauth_registration_required?` hook to return `true` in its OAuth controller. The callback stores a protected OAuth continuation for `pending_authentication_ttl` and redirects to sign-up. The form builds the account with `new_from_omniauth`; its POST merges only host-permitted account fields and atomically creates the account, OAuth identity, and registration identity or tenant. Provider and UID always come from the protected session payload, never request parameters. Invalid, expired, or malformed context is cleared and normal sign-up resumes.

## Sessions and hooks

Authentication rotates the session. By default, CSRF, flash, locale, return destination, credential drafts, and a pending invitation survive. Intermediate authentication context is scoped to its flow.

```ruby
Vouch.configure do |config|
  config.preserved_session_keys = ["cart"]
  config.preserved_auth_scopes = [:admin]
end
```

Preserved scopes are re-established through Warden serialization. Declare only host state that should cross an authentication boundary. Arbitrary session keys and authentication scopes are not copied automatically.

Credential drafts retain the existing `credential_drafts` getter/setter contract. The default value is an empty hash; hosts define their own credential-type keys. Direct ActiveRecord objects require a host session serializer that round-trips their attributes and challenge state. A JSON cookie store does not provide that automatically. Hosts should encode drafts explicitly or use an appropriate server-side session store. Candidate identity lists and draft payloads must fit the selected store's size limits. Never deserialize client-supplied class names without a host allowlist.

Lifecycle hooks support `before_*`, `after_*`, and `around_*`: sign_in, sign_out, sign_up, oauth_sign_in, oauth_link, oauth_account_creation, impersonation_start, and impersonation_end. Event hooks use `on_*`: password_reset_token_generation, password_change, invitation_token_generation, invitation_acceptance, and two_factor_verification.

```ruby
class Users::PasswordsController < Vouch::PasswordsController
  on_password_reset_token_generation do |account, token|
    AccountMailer.password_reset(account, token).deliver_later
  end
end
```

Sign-in, registration, and OAuth account-creation run `before_*`, `around_*`, core work, and `on_*` hooks inside their database transaction. A halted hook or an `ActiveRecord::Rollback` raised inside that authentication operation does not establish a session. Do not wrap an auth-controller action in an outer transaction that can roll back after the action yields: Rails session and Warden mutation are not database-transactional, so they cannot be rolled back with application records. Registration rollback removes its account and membership changes. Warden `after_authentication` fires once with the final identity, after required factors and selection. Password verification alone does not fire Warden user callbacks.

Lifecycle `after_*` callbacks run only after a successful lifecycle operation and after every open joinable Active Record transaction has committed. They therefore do not run when an enclosing host transaction rolls back. Sign-in, sign-up, and OAuth account-creation callbacks run after the resulting session state has been published; sign-up and OAuth account creation describe successful account creation even if a later identity selection cannot complete. Sign-out and impersonation callbacks run after Warden and session state change. An after-callback exception cannot undo a committed operation. Use the supplied identity argument inside sign-in hooks; `current_identity` is bound only after authentication succeeds.

A successful second factor remains part of the completion hook context through identity selection. OAuth continuation stores a protected-session payload containing provider, UID, and the default profile fields email, name, and image. It never retains provider access or refresh tokens. The selected provider fields have no imposed length bound, so cookie-session hosts that need stricter size limits should override protected `serialize_oauth` and `parse_oauth` together with a bounded, serializable representation. The original callback AuthHash is available during immediate callback completion and `oauth_account_creation`; after MFA or identity selection, `oauth_sign_in` hooks and profile updates receive the reconstructed payload. Delivery exceptions propagate to host controllers, which should translate expected delivery failures into the desired response.

Existing-account OAuth profile updates run inside the final `oauth_sign_in` lifecycle transaction. They wait for required MFA and identity selection. A before-hook abort skips the update, and a transaction rollback reverses it. Profile-update overrides receive the original provider payload for immediate completion and the reconstructed compact AuthHash after continuation.

## Verification and second factors

Two-factor support ships without a TOTP library. Like OmniAuth, `rotp` is opt-in:
add `gem "rotp"` to the host Gemfile when a credential uses TOTP. Vouch itself
does not depend on it.

Include `Verifiable` on models whose subject must be confirmed. Declare the natural subject explicitly:

```ruby
class Phone < ApplicationRecord
  include Vouch::Verifiable
  include Vouch::TwoFactorable
  include Vouch::MagicLinkable
  self.verifiable_subject_attribute = :e164
  belongs_to :account

  def deliver_verification_code(code)
    SmsCourier.send(e164, code)
  end
end
```

Use the Verifiable, TwoFactorable, and MagicLinkable generators for required fields. Verifiable requires `verification_version` and `verification_nonce`. MagicLinkable requires `sign_in_nonce`, and TwoFactorable requires `two_factor_nonce`. Keep each feature’s existing timestamps and counters. These nullable string nonces belong to the credential row. Schema validation runs when the feature is used, so loading classes does not block their migrations.

```ruby
result = phone.start_verification!
session[verification_key] = result.token if result.ok?
phone.complete_verification!(params[:code], token: session[verification_key])
phone.enable_two_factor!
```

Subject changes clear verification and advance its version. Tokens bind to the subject/version. Changing A to B and back to A does not revive an earlier token. Successful verification rechecks the current row under its lock. Each persisted challenge is single-use. A new issuance retires the previous challenge for that flow, including when delivery subsequently fails. Verification, sign-in, and second-factor flows use independent nonces. `unverify!` clears verification and all outstanding flow nonces. Unrelated updates do not invalidate challenges. Use normal model writes for subject changes; callback-bypassing database writes require explicit equivalent invalidation.

Unsaved drafts can verify in memory and later persist with their account. Editing a verified draft invalidates that verification. Draft lockout and nonce consumption exist only in memory until persistence. Hosts must protect draft session state and apply request limits. Persisted challenge replay protection does not apply to restored copies of an unsaved draft.

`challenge!` returns `Result.ok(token)` or `Result.locked`. `verify_challenge(code, token:)` returns a `Result` with `ok?`, `invalid?`, `locked?`, and `cancelled?` predicates. Disabled or unverified credentials cannot satisfy 2FA. Challenge session keys include both model and ID. `CredentialSet` supports account-scoped lookup and typed opaque IDs, including UUIDs. Use `<model>-<id>` for multi-association routes; an unknown type prefix falls back to a bare-ID lookup across the configured associations.

Account MFA is a persisted preference. A credential can be verified and ready
while the account preference is `false`; enrolling or enabling a credential does
not turn account MFA on. Call `account.enable_two_factor!` after enrollment; it
requires a usable verified, enabled, unlocked credential. Call
`account.disable_two_factor!` to opt out explicitly. While MFA is on, direct
credential disable and destroy operations lock the account and prevent removal
of the final usable factor. Hosts can override
`two_factor_last_factor_removal_action(credential)` to return `:disable`, which
clears the account preference in the same transaction. For a custom account
column, set `self.two_factor_enabled_attribute` or override
`write_two_factor_enabled!`.

Mappings that expose non-empty two-factor credential association sets for the
same account class must agree. Scopes without factor associations do not add a
conflict. Inconsistent mappings raise `Vouch::ConfigurationError`;
configure matching associations explicitly with
`associations: {two_factorable: [...]}` when a host needs an override.

Two-factor settings can be overridden per owning account model. Omitted keys use the global values:

```ruby
class Account < ApplicationRecord
  authenticates_with :two_factorable,
    two_factorable: { max_attempts: 3, lockout_duration: 10.minutes }
end
```

When a credential has multiple qualifying account owners, select one explicitly in the credential model:

```ruby
def two_factor_account_class
  Account
end
```

If a credential has more than one distinct MFA-enabled owner record (for
example, `account` and `creator`), override the instance owner explicitly:

```ruby
def two_factor_account
  creator
end
```

Vouch raises an ambiguity error instead of choosing the first
association by reflection order.

TOTP/WebAuthn hosts override challenge and verification methods to implement their protocol. These overrides must enforce eligibility, lockout, version binding where relevant, and replay prevention. The dummy TOTP model demonstrates the integration. The gem does not mandate ROTP for email/SMS factors.

Magic-link hosts call `issue_sign_in_code!` and `verify_sign_in_code`. After verification, record `{"type", "id"}` in `signed_in_via_session_key` and call `complete_sign_in(account, method: :magic_link)`. Hosts may instead pass the verified credential directly with `signed_in_via: credential`. Vouch uses this only to exclude the primary credential from a later second-factor picker; the host remains responsible for verifying the proof first. Host controllers own issuance rate limits and recovery UI.

OtpCourier receives Rails key material through its integration. Nonstandard initialization must configure its secret explicitly. Hosts must implement each credential's delivery method (`deliver_verification_code`, `deliver_sign_in_code`, or `deliver_two_factor_code`); the default raises `Vouch::ConfigurationError` so an unconfigured flow cannot report success without delivery.

## Password reset and recovery

Password reset uses a random token with only its SHA-256 digest stored in the database:

```ruby
token_result = account.generate_password_reset_token!
token = token_result.value
account = Account.find_by_auth_password_reset_token(token)
account.reset_password_with_token!(token, password: new_password,
  password_confirmation: confirmation)
```

The gem-specific lookup avoids Rails' native `find_by_password_reset_token` API. Both public APIs reject blank or non-String tokens before hashing: the lookup returns `nil` and consumption returns `Result.invalid`. Reset consumption locks and rechecks the token while changing the password and clearing reset state. Validation failure preserves the token. Any persisted password change clears outstanding reset state, including changes outside the reset controller. Password history rejects both the current password and configured archived passwords.

Recoverable provides account-level BCrypt-hashed codes. BackupCodable provides per-credential codes. Generate plaintext once, show it to the user, and store only digests. Consumption and regeneration serialize on the owner so concurrent requests cannot consume a code twice. When a credential includes both `TwoFactorable` and `BackupCodable`, BackupCodable is automatically tried as an alternate `verify_challenge` proof before the credential's normal verifier runs; successful consumption clears that credential's failed-factor state and records use atomically. This does not make backup codes account-level recovery codes. Custom flows that do not call `verify_challenge` use `consume_backup_code!` directly and retain their own authorization and rate-limit policy. Recovery randomness uses SecureRandom. Model `recoverable:` options override global defaults.

Signed `TokenVerifiable` links bind to a nonce that rotates atomically on consumption. Generate them only from persisted records; drafts and destroyed records raise rather than creating a token with no durable nonce. Configure mutable recipients explicitly:

```ruby
class EmailConfirmation < ApplicationRecord
  include Vouch::TokenVerifiable::Concern
  self.token_subject_attribute = :email_address
end
```

Tokens also bind to that attribute. A saved recipient change clears verification and rotates the nonce, including changes from A to B and back. Without this option, links retain record-bound semantics. Hosts own delivery, route authorization, and equivalent invalidation for callback-bypassing writes.

## Persistence and host callbacks

Authentication proof consumption must commit its state changes before reporting success. Built-in verification, reset, backup-code, and recovery operations detect callbacks that raise `ActiveRecord::Rollback`. They roll back the operation and return failure. Signed verification returns `nil`, while the other proof consumers return `false`.

Issuance and state-change methods raise `Vouch::Persistence::Cancelled`, a subclass of `ActiveRecord::RecordNotSaved`, when a callback silently cancels persistence. They do not return usable proofs or publish authentication success. Unexpected database errors and explicit callback abort exceptions retain their normal exception behavior.

These operations use database transactions and savepoints. Host callbacks still control validation and persistence. External effects in callbacks cannot be undone by a database rollback. Hosts should arrange delivery and other external effects after successful persistence.

Host-defined two-factor credentials can use the optional [RSpec adapter contract](docs/credential-adapter-contract.md). It checks issuance, invalid proofs, replay, expiry, stale instances, disabled credentials, and persistence failures. RSpec remains a test dependency of the host.

## Invitations and impersonation

Accounts use persisted `registration_required` state to distinguish placeholders from registered accounts. Each invitation also records `invitation_registration_required`. Registration requires both flags, so multiple pending invitations cannot reopen registration after signup succeeds. New-account acceptance completes the invited identity in its original tenant. Existing-account invitations require authentication and cannot change that account's password. Expired or revoked invitations fail, including when a browser retains old invitation state.

Invitation creation is denied until the host controller defines `authorize_invitation!`. The hook must return without rendering or raising only when the current identity may invite. The default revocation relation includes only pending invitations issued by the current identity, within its tenant where applicable. Override `revocable_invitations` to use a host authorization policy. Add `Vouch::Invitable::Concern` to the identity model generated for the scope, then declare `belongs_to :inviter, class_name: "YourIdentity", optional: true` and `has_many :invitees, class_name: "YourIdentity", foreign_key: :inviter_id, dependent: :nullify`; the concern supplies the invitation persistence API while these host associations define ownership behavior. `build_invited_identity` must return a persisted account. Set `registration_required: true` when creating a placeholder. Reuse existing accounts without changing their registration state. The generated controller follows this contract.

`IdentityModel.invite!` returns `Vouch::Result.ok(invitee)`; use `.value` to access the persisted invitation record. Persistence cancellation still raises `Vouch::Persistence::Cancelled`.

Successful invited signup clears the account flag in the same transaction as the password update and invitation acceptance. Hosts with their own onboarding state can override `registration_required?` and `complete_registration!` on the account. The completion method must persist its change within the current transaction.

Revocation removes the pending identity in split-model scopes or clears the invitation token on a single-model account. It does not delete host-owned accounts. Register an `around_invitation_revocation` hook when the host wants to remove a disposable placeholder account; the hook runs inside the invitation transaction, so a cancelled account destruction rolls back the invitation revocation. Keep account retention and cross-scope references in the host policy.

For existing installations, add `registration_required` to the account table as a non-null boolean with a default of `false`. Set it to `true` for accounts that still await invited registration, including retained placeholders without an invitation. Update the host invitation builder to mark new placeholders. Existing registered accounts must keep `false`. For new installations, the invitations generator supplies the migration once per account table. `build_invited_identity(identifier)` returns the persisted authentication account model selected by the route mapping, regardless of its class name. Hosts using another identifier should override the hook and keep their own lookup and validation rules.

`accept_invitation!` locks and reloads the invitation before checking its token and expiry. A stale instance cannot accept an already accepted, revoked, expired, or replaced invitation.

When the identity model differs from the authentication route scope, specify the scope and controller namespace independently:

```sh
bin/rails g vouch:invitations Admin::Member Account --auth-scope user --controller-path users
```

This extends the `Admin::Member` table and generates `Users::InvitationsController` for the `:user` mapping. `--controller-path` is the namespace directory, such as `users` or `api/members`.

For a single-model `:member` scope, generate the editable controller and form
with:

```sh
bin/rails g vouch:invitations members --single-model --auth-scope member --controller-path members
```

This creates `Members::InvitationsController` with a fail-closed
`authorize_invitation!` stub and an illustrative email-based
`build_invited_identity` recipe. Replace both with the host's authorization,
identifier normalization, validation, and required attributes before enabling
`auth.invitations`. The host must also include `Vouch::Invitable::Concern`
and declare its invitation associations on the model.

Add impersonation to an existing scope and generate its host-owned controller:

```sh
bin/rails g vouch:impersonation users
```

The generator adds `auth.impersonation` to the unique existing `auth.scope :user` block and writes `Users::ImpersonationsController`. It safely denies access until the host replaces `authorize_impersonation!` with its own authorization rule. When a controller namespace differs from its authentication scope, pass `--auth-scope`, for example `bin/rails g vouch:impersonation portal --auth-scope user`.

Impersonation denies access by default. Hosts must override `authorize_impersonation!` to enforce their authorization policy. Session rotation preserves the original identity explicitly, and stop restores it across requests. Switching targets keeps that same original operator; both stop endpoints return to the original operator, with no nested stack. A locked operator or changed password fingerprint prevents restoration. The gem does not define an administrator role.

## Reflection and existing Warden integration

Only enabled features undergo concern discovery. Hosts can restrict discovery to explicit associations:

```ruby
auth.scope :user, account: "Account", identity: "User",
  associations: {two_factorable: [:phones, :authenticators]}
```

Account, identity, and tenant relationships use one flat hash when automatic discovery is ambiguous.

```ruby
auth.scope :member, account: "Owner", identity: "Membership", tenant: "Workspace",
  path: "members", as: :member,
  associations: {
    account_identities: :memberships,
    identity_account: :owner,
    identity_tenant: :workspace,
    tenant_identities: :memberships
  } do
    auth.sessions(path_names: {sign_in: "login"}, controller: "members/sessions")
  end
```

Omit these overrides when each target has exactly one matching association. Polymorphic associations are excluded from automatic relationship discovery. Paths, route helpers, selected features, and controller overrides remain independent of model association names.

OAuth identity ownership resolves separately from membership ownership. A membership can belong to `:owner` while its OAuth identity belongs to polymorphic `:account`. The resolver uses the account's OAuth association and its inverse metadata. For ambiguous ownership, set `associations: {oauth_account: :owner}` to name the OAuth identity's `belongs_to`. This does not change `identity_account`.

The generator covers the ordinary one-owner relationship. Keep a legacy,
nonstandard, or polymorphic ownership design explicit in the host. For example,
when an OAuth model calls its account owner `owner`, configure both the account
collection and the inverse owner:

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

A polymorphic identity can retain `belongs_to :account, polymorphic: true` and
`has_many :oauth_identities, as: :account`. Configure
`omniauthable: :oauth_identities`; add `oauth_account: :account` whenever more
than one `belongs_to` could own the OAuth row. `oauth_account` names the OAuth
identity owner only. It does not replace `identity_account`, which remains the
membership-to-account relationship.

Password-history association selection belongs to the account model:

```ruby
class Owner < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password
  has_many :password_archives, class_name: "PasswordArchive", foreign_key: :owner_id
  authenticates_with :password_trackable,
    password_trackable: {association: :password_archives}
end
```

The archive model includes `Vouch::PasswordArchive::Concern`. Omit the `association` option when discovery finds exactly one archive association. Every route scope for this account uses the same selection. Password validation also works without any registered routes. Move conflicting route-level `associations[:password_trackable]` configuration to the model.

Password-history correctness across concurrent updates belongs to the host's write policy. If multiple requests can change a password, lock and reload the account before assigning the new password:

```ruby
account.with_lock do
  account.update!(password: new_password, password_confirmation: new_password)
end
```

Apply the same policy to every host password-writing path. A lock acquired after assigning a password on a stale object does not refresh the history used by that assignment. Database constraints and any optimistic locking policy also remain host responsibilities.

Without overrides, the gem discovers feature associations by concern inclusion. Ambiguous single-association features raise a configuration error. Explicit associations are validated. Resolver names and model references resolve through current Rails classes after reloading. The gem does not change global OTP/SMS inflections.

For an existing Warden middleware stack:

```ruby
Vouch.configure { |config| config.install_middleware = false }
# In the host's existing Warden configuration block:
Vouch.configure_warden(manager)
```

A mapping named `:member` reserves Warden scopes `:member`, `:member_account`, and `:member_impersonation`. These hold the authenticated identity, pending account, and impersonation restoration identity. Every mapping follows this naming rule. The strategy name `:password` is also reserved.

Vouch rejects collisions between its own mappings and their derived scopes. Choose mapping names that do not overlap host scopes. Other gems must not register different serializers or authentication behavior for these reserved scopes; the host owns that coordination.

Vouch applies its strategies to registered scopes. It preserves existing host defaults and failure handling when supplied. Configure the host failure app to route Vouch scope failures appropriately. The gem uses Warden directly and does not install rails_warden monkey patches.

## Upgrading existing schemas

Fresh feature generators include the new columns. Existing installations need an application migration before using the updated concerns:

```ruby
class AddAuthenticationProofState < ActiveRecord::Migration[8.0]
  def change
    # Use your actual credential tables and only their enabled features.
    add_column :phones, :verification_nonce, :string
    add_column :phones, :sign_in_nonce, :string
    add_column :phones, :two_factor_nonce, :string
    add_column :accounts, :consecutive_locks, :bigint, default: 0, null: false
  end
end
```

Each lock event increments `consecutive_locks`. Expiry permits another attempt. A subsequent failed attempt locks again with doubled duration, up to the existing cap. Successful authentication clears both attempt and lock counters. Existing rows start with zero recorded lock events.

Outstanding OTP challenges without nonces become invalid. The unified session fingerprint invalidates older sessions on their next request. Plan rollout and sign-in messaging accordingly.

## Development and validation

```sh
bundle install
bundle exec rspec
```

Regression tests cover request/session boundaries, generated models, scope routing, subject edits, token races, and extension policies. Compatibility CI runs the full host suite on Rails 8.0 and 8.1 against released dependencies. PostgreSQL is the tested database. Ordinary scalar primary keys, including UUIDs and renamed keys, are supported. Composite keys are outside this contract. Cookie and server-side session storage remain host choices.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/NicolasJJensen/rails_vouch.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
