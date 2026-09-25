# Sign in with OAuth

Vouch uses OmniAuth to sign users in through providers such as GitHub. OmniAuth handles the provider exchange; Vouch connects the returned provider identity to your credentials model.

## Add GitHub sign-in

Starting with your Vouch `User` model:

```sh
bundle add omniauth omniauth-github omniauth-rails_csrf_protection
bin/rails generate vouch:omniauth User --provider github
bin/rails db:migrate
```

The generator adds:

- `OauthIdentity`, associated with your `User` model.
- `Users::OmniAuthsController` and the provider callback routes.
- `config/initializers/vouch_omniauth_github.rb`.
- A migration for provider identities:

```ruby
create_table :oauth_identities do |t|
  t.bigint :user_id, null: false
  t.string :provider, null: false
  t.string :uid, null: false
  t.json :auth_data
  t.timestamps
end
add_index :oauth_identities, [:provider, :uid], unique: true
add_index :oauth_identities, :user_id
add_foreign_key :oauth_identities, :users
```

The generator keeps an existing OAuth table and recognizes an existing migration that creates it. Existing model and controller customizations are preserved.

For a **multi-tenant application**, generate against the account instead:

```sh
bin/rails generate vouch:omniauth Account --provider github
```

That migration uses `account_id` and a foreign key to `accounts`. Controllers and callback paths use `accounts`. Memberships and organisations are created during [registration](#create-an-organisation-during-signup).

On Rails 8.2 and newer, the initializer reads combined credentials:

```ruby
# config/initializers/vouch_omniauth_github.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    Rails.app.creds.require(:github, :client_id),
    Rails.app.creds.require(:github, :client_secret),
    path_prefix: "/users/auth"
end
```

For earlier Rails versions, the generator uses `Rails.application.credentials.dig(:github, :client_id)` and the corresponding secret lookup.

Create an OAuth application in GitHub, put its client ID and secret under `github` in Rails credentials, and set its callback URL to your application URL followed by `/users/auth/github/callback`.

Start sign-in with a POST button. The CSRF protection gem validates the request before OmniAuth sends the user to GitHub:

```erb
<%= button_to "Sign in with GitHub", "/users/auth/github", data: { turbo: false } %>
```

### What happens during sign-in?

1. The button posts to OmniAuth's `/users/auth/github` endpoint.
2. GitHub asks the person to authorize your application.
3. GitHub returns them to `/users/auth/github/callback`. OmniAuth validates the response and passes the provider identity to Vouch.
4. Vouch signs in the linked user, or creates a user when the provider identity is new.

If the user is already signed in, the callback links GitHub to that user. It cannot take a provider identity already linked to someone else. OmniAuth supplies a provider name and a stable provider user ID (`uid`). Those identify the linked login independently of whether your own sign-in form uses an email or username. Matching email alone does not link accounts.

For a custom OAuth model, override `find_from_omniauth` and `oauth_attributes` together to change lookup and persistence. The default concern validates `provider` and `uid`; custom column names also need matching validations and a unique database index.

MFA still applies according to your [authentication policy](authentication-policy.md). A requested membership selection continues after the credentials login completes.

## Ask for registration details first

If signup requires information the provider does not supply, send new OAuth users through your registration form:

```ruby
# app/controllers/users/omni_auths_controller.rb
class Users::OmniAuthsController < Vouch::OmniAuthsController
  private

  def oauth_registration_required?
    true
  end
end
```

Add the fields to your registration form and permit them in its controller, for example:

```ruby
# app/controllers/users/registrations_controller.rb
class Users::RegistrationsController < Vouch::RegistrationsController
  private

  def account_params
    params.require(:user).permit(:email_address, :name, :password, :password_confirmation)
  end
end
```

Vouch builds the account from the retained provider data, then assigns the permitted registration fields. Submitted profile fields therefore override those defaults. Provider and UID come from protected session state, not form fields.

Account creation, the OAuth link and the records returned by [identity construction](#create-an-organisation-during-signup) are saved in one transaction. Vouch then completes any required MFA before sign-in.

The default creation mapping copies the provider email and assigns an unguessable password. To also prefill a name, add this to your credentials model:

```ruby
 def self.oauth_attributes_for_creation(auth_hash)
   super.merge(name: auth_hash.info.name)
 end
```

This example assumes your model has a `name` attribute. Configure how long the person may leave the registration form open:

```ruby
Vouch.configure do |config|
  config.pending_authentication_ttl = 15.minutes
end
```

## Create an organisation during signup

Override `build_tenant` and `build_identity` to construct the organisation and membership accompanying a new account. They return unsaved records; Vouch saves them in the same transaction as the account and OAuth link.

To collect the organisation name, add a field to the registration form:

```erb
<%= text_field_tag "organisation[name]", params.dig(:organisation, :name), required: true %>
```

Then share the construction methods between password registration and OAuth signup:

```ruby
# app/controllers/concerns/provisions_organisation.rb
module ProvisionsOrganisation
  extend ActiveSupport::Concern

  private

  def build_tenant(_account)
    Organisation.new(params.require(:organisation).permit(:name))
  end

  def build_identity(account, tenant:)
    tenant.users.build(account: account)
  end
end
```

```ruby
# app/controllers/accounts/registrations_controller.rb
class Accounts::RegistrationsController < Vouch::RegistrationsController
  include ProvisionsOrganisation
end

# app/controllers/accounts/omni_auths_controller.rb
class Accounts::OmniAuthsController < Vouch::OmniAuthsController
  include ProvisionsOrganisation

  private

  def oauth_registration_required?
    true
  end
end
```

The extra registration step supplies the organisation name that OAuth does not provide. Use [transactional hooks](sessions-and-hooks.md) for accompanying records such as preferences. The password-based invitation flow reuses its existing membership and organisation. Deferred OAuth signup is for creating a new account; it does not replace invitation registration.

## Routes and other providers

| Endpoint | Handled by | Purpose |
| --- | --- | --- |
| `POST /users/auth/github` | OmniAuth middleware | Start the provider exchange. |
| `GET /users/auth/github/callback` | `Users::OmniAuthsController#callback` after OmniAuth | Complete login, signup, or linking. |
| `GET /users/auth/failure` | `Users::OmniAuthsController#failure` | Return to sign-in after failure. |

Other providers may use different callback methods. Match the OmniAuth strategy's configuration and your Vouch route declaration, for example:

```ruby
# config/routes.rb, inside the User scope
 auth.oauth_callbacks callback_methods: [:get, :post]
```

`callback_path:` and `failure_path:` customize Vouch's callback URLs. Set the corresponding paths in OmniAuth and in the provider's application settings too: all three describe the same return destination.

For a nonstandard controller namespace:

```sh
bin/rails generate vouch:omniauth User --provider github --auth-scope user --controller-path portal
```

For the model and migration alone:

```sh
bin/rails generate vouch:omniauth User --model-only
```

Both use the OAuth identity schema above. The second omits the controller, routes and provider initializer.

## Advanced: retained provider data

Deferred registration keeps provider, UID, email, name and image. To retain an additional profile field while the registration form is open, override the serialization in a controller concern shared by the OAuth and registrations controllers:

```ruby
module RetainsProviderNickname
  private

  def serialize_oauth(auth_hash)
    super.tap do |payload|
      payload["info"]["nickname"] = auth_hash.info.nickname.to_s.first(100)
    end
  end
end
```

The existing `parse_oauth` already reconstructs this hash as an `OmniAuth::AuthHash`. Override both methods if you change the representation itself.

To save the retained value, add your model's mapping:

```ruby
# In the credentials model, with a provider_nickname attribute
 def self.oauth_attributes_for_creation(auth_hash)
   super.merge(provider_nickname: auth_hash.info.nickname)
 end
```

Access and refresh tokens are not retained in the continuation. If your application needs provider API access, store tokens separately using encrypted storage and carry a reference through the continuation rather than placing provider credentials in session data.

## Advanced: shared OAuth storage

The default OAuth owner is a concrete model. If several credentials classes share an OAuth table, existing polymorphic ownership is supported:

```ruby
class OauthIdentity < ApplicationRecord
  include Vouch::OAuthIdentity::Concern
  belongs_to :oauthable, polymorphic: true
end

class Account < ApplicationRecord
  has_many :oauth_identities, as: :oauthable, dependent: :destroy
end
```

This requires `oauthable_type` and `oauthable_id` columns. Select nonstandard association names through `associations: { omniauthable: :oauth_identities, oauth_account: :oauthable }` on the credentials scope. Core account/membership and tenant/membership associations remain concrete.

## Edit the callback actions

```sh
bin/rails generate vouch:eject users omni_auths
```

This creates `app/controllers/users/omni_auths_implementation_controller.rb` and makes your existing `OmniAuthsController` inherit from it, retaining your overrides. See [ejection](controllers.md#eject-a-controller) for the resulting controller structure and remaining Vouch dependencies.
