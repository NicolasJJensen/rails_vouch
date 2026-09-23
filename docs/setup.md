# Setup and generators

This guide covers setup choices beyond the baseline installation in the [README](../README.md). See [model mapping](model-mapping.md) for relationship overrides and [upgrading](upgrading.md) for existing schemas.

## Generators and custom names

The installer adds configuration and a routes block. The scope generator creates the selected models, migrations, controllers, views, and routes. Generate account and membership scopes for a multi-tenant application with:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
bin/rails db:migrate
```

For a single model, use `bin/rails generate vouch:scope members Member --single-model`. Generator primary-key options support UUID hosts. Namespaced model arguments such as `Admin::Account` and `Admin::Phone` are supported; generators create namespace paths and explicit table names where Rails needs them. Already loaded models provide table metadata, but generators do not trigger model autoloading before migrations, so inspect migrations for custom tables when a model is not loaded.

Generated account models include email normalization and presence/case-insensitive uniqueness validation, backed by the generated database index. Keep or adapt these defaults when using another identifier. Repeated route generation preserves an existing scope; ambiguous routes are left untouched with manual instructions.

Feature generators use the same model naming rules. For account-owned password reset and MFA, target the account scope and its controller namespace:

```sh
bin/rails g vouch:password_resetable Account --auth-scope account --controller-path accounts
bin/rails g vouch:two_factorable Totp --auth-scope account --controller-path accounts
```

These commands generate subclasses with `auth_scope :account` and views under `app/views/accounts`. Password reset also wires the model, route, mailer, and delivery hook. Review any generator message about a target it could not identify. For MFA, add `auth.two_factor` to the account scope and complete the model and schema steps in the [MFA guide](verification-and-mfa.md). The two-factor command generates sign-in challenge UI only; enrollment remains host-owned because each credential type needs its own permitted fields and enrollment protocol. Omit both UI options to skip controller, view, and mailer generation.

See [invitations](invitations.md), [impersonation](impersonation.md), and [controller ejection](controllers.md#copying-an-endpoint-into-your-application) for their generator options. Forms use the account's `model_name.param_key`, so `Admin::Account` normally uses `admin_account`.

## Non-email identifiers

The baseline scope uses `email_address`. When replacing it with `login`, remove the generated email presence/uniqueness validation and replace the normalization with the login rules below. If you retain email as an optional field, choose its validation rules explicitly. For a non-email login identifier, keep lookup, account creation, and generated host views in the host. Add the identifier column and make `email_address` optional if login replaces it, adapting the table name for a custom account table:

```ruby
class AddLoginToAccounts < ActiveRecord::Migration[8.0]
  def change
    change_column_null :accounts, :email_address, true
    add_column :accounts, :login, :string, null: false
    add_index :accounts, :login, unique: true
  end
end

class Account < ApplicationRecord
  normalizes :login, with: ->(value) { value.strip.downcase }
  validates :login, presence: true, uniqueness: true
end
```

Register a resolver after loading its host class. It receives top-level session parameters and the mapped account class:

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

# Load a host resolver before registering it from an initializer.
# Keep it in an autoloaded host file such as app/models/login_resolver.rb.
require Rails.root.join("app/models/login_resolver").to_s
Vouch.configure { |config| config.register_login_resolver LoginResolver }
```

Replace the generated registrations controller's `account_params`; account attributes are nested under the mapping's account parameter key. Keep password fields permitted and replace `:email_address` with `:login`:

```ruby
# app/controllers/accounts/registrations_controller.rb
class Accounts::RegistrationsController < Vouch::RegistrationsController
  private

  def account_params
    params.require(auth_mapping.account_param_key).permit(:login, :password, :password_confirmation)
  end
end
```

The session form submits top-level `login`; the registration form submits nested `login` under the account key:

```erb
<!-- app/views/accounts/sessions/new.html.erb: replace the email field -->
<%= label_tag :login %>
<%= text_field_tag :login, params[:login], autocomplete: "username", required: true %>

<!-- app/views/accounts/registrations/new.html.erb: nested account attribute -->
<%= form.label :login %>
<%= form.text_field :login, value: @account.login, autocomplete: "username", required: true %>
```

Apply the same parameter rule to custom registration and OAuth completion views. Invitation `build_invited_identity(identifier)` must normalize the identifier, find or create a persisted account, and set `registration_required: true` only on a new placeholder. Identifier, account, and tenant fields remain host-owned.

## Optional dependencies and verification

Core dependencies are Warden, BCrypt, active_hooks, and otp_courier. OmniAuth and provider gems are opt-in. ROTP is opt-in for TOTP, and QR rendering is a host responsibility. Enable only installed concerns and add their generated columns and associations.

After models are loaded, `Vouch.verify!` or `bin/rails vouch:verify` checks account, identity, tenant, OAuth, and credential associations and feature contracts without changing schema. Token-verifiable records are standalone host credentials; validate their columns separately because the boot verifier cannot discover every such model. The dummy app exposes the same task as `app:vouch:verify`.

## Model responsibilities

Enable only the features whose migrations and associations you have installed. The credentials model owns identifier normalization and password validation. Memberships own their account and optional tenant associations. Feature guides show their additional model requirements; avoid enabling every concern before supplying its schema.

For shared credentials with additional membership scopes, reuse the same account scope and add a linked membership scope. Account scope names are inferred from the credentials model unless `--account-scope` is supplied. Read [model mapping](model-mapping.md) before using shared user/admin credentials.

When an existing table has records, backfill new required fields before adding non-null constraints. The non-email migration above is illustrative for an empty table; production data requires a staged backfill.
