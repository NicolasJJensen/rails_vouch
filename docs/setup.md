# Advanced setup

This guide covers setup choices beyond the baseline installation in the [README](../README.md). See [model mapping](model-mapping.md) for relationship overrides and [upgrading](upgrading.md) for existing schemas.

## Generators and custom names

If the install generator reports that `Vouch.routes(self)` should be pasted into `config/routes.rb`, paste that scaffold before running the scope generator:

```sh
bin/rails generate vouch:scope users Account:account User:identity Organisation:tenant
bin/rails db:migrate
```

For a single model, use `bin/rails generate vouch:scope members Member --single-model`. Generator primary-key options support UUID hosts. Namespaced model arguments such as `Admin::Account` and `Admin::Phone` are supported; generators create namespace paths and explicit table names where Rails needs them. Already loaded models provide table metadata, but generators do not trigger model autoloading before migrations, so inspect migrations for custom tables when a model is not loaded.

Feature generators use the same model naming rules. Password-reset and two-factor UI generation requires both the model argument and the route scope/controller namespace:

```sh
bin/rails g vouch:password_resetable Account --auth-scope user --controller-path users
bin/rails g vouch:two_factorable Totp --auth-scope user --controller-path users
```

These commands generate subclasses with `auth_scope :user` and views under `app/views/users`. Add the matching `auth.passwords` or `auth.two_factor` route yourself. The two-factor command generates sign-in challenge UI only; enrollment remains host-owned because each credential type needs its own permitted fields and enrollment protocol. Omit both UI options for migration-only generation.

See [invitations](invitations.md), [impersonation](impersonation.md), and [controller ejection](controllers.md#ejecting-a-controller) for their generator options. Forms use the account's `model_name.param_key`, so `Admin::Account` normally uses `admin_account`.

## Non-email identifiers

The baseline scope uses `email_address`. For a non-email login identifier, keep lookup, account creation, and generated host views in the host. Add the identifier column and make `email_address` optional if login replaces it, adapting the table name for a custom account table:

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
# app/controllers/users/registrations_controller.rb
class Users::RegistrationsController < Vouch::RegistrationsController
  private

def account_params
  params.require(auth_mapping.account_param_key).permit(:login, :password, :password_confirmation)
end
end
```

The session form submits top-level `login`; the registration form submits nested `login` under the account key:

```erb
<!-- app/views/users/sessions/new.html.erb: replace the email field -->
<%= label_tag :login %>
<%= text_field_tag :login, params[:login], autocomplete: "username", required: true %>

<!-- app/views/users/registrations/new.html.erb: nested account attribute -->
<%= form.label :login %>
<%= form.text_field :login, value: @account.login, autocomplete: "username", required: true %>
```

Apply the same parameter rule to custom registration and OAuth completion views. Invitation `build_invited_identity(identifier)` must normalize the identifier, find or create a persisted account, and set `registration_required: true` only on a new placeholder. Identifier, account, and tenant fields remain host-owned.

## Optional dependencies and verification

Core dependencies are Warden, BCrypt, active_hooks, and otp_courier. OmniAuth and provider gems are opt-in. ROTP is opt-in for TOTP, and QR rendering is a host responsibility. Enable only installed concerns and add their generated columns and associations.

After models are loaded, `Vouch.verify!` or `bin/rails vouch:verify` checks account, identity, tenant, OAuth, and credential associations and feature contracts without changing schema. Token-verifiable records are standalone host credentials; validate their columns separately because the boot verifier cannot discover every such model. The dummy app exposes the same task as `app:vouch:verify`.

## Host-owned model baseline

An account commonly includes the following, adding only features installed by the host:

```ruby
class Account < ApplicationRecord
  include Vouch::Authenticatable
  authenticates_with :lockable, :password_resetable, :password_trackable,
    :two_factorable, :omniauthable, :recoverable
  has_secure_password
  has_many :users
  has_many :oauth_identities, class_name: "OauthIdentity", foreign_key: :account_id,
    dependent: :destroy
  has_many :two_factor_credentials
  has_many :password_archives
end
```

Host models own identifier normalization, database constraints, password validation, associations, and delivery. PostgreSQL is the tested database. Ruby must be >= 3.2 and Rails >= 8, < 9; individual Rails versions may impose higher Ruby minimums.
