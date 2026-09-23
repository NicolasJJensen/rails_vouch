# Sign in with OAuth

Vouch uses OmniAuth to sign users in through providers such as GitHub. OmniAuth handles the provider exchange; Vouch connects the returned provider identity to your credentials model.

## Add GitHub sign-in

Starting with your Vouch `User` model:

```sh
bundle add omniauth omniauth-github omniauth-rails_csrf_protection
bin/rails generate vouch:omniauth User --provider github
bin/rails db:migrate
```

The generator creates an `OauthIdentity` model and table, connects it to `User`, enables the OAuth feature, and adds a callback controller, routes, and provider initializer. For a multi-tenant setup with passwords on `Account`, pass `Account` instead. The provider login belongs to the same model as the password.

The initializer reads your provider credentials:

```ruby
# config/initializers/vouch_omniauth_github.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    Rails.application.credentials.dig(:github, :client_id),
    Rails.application.credentials.dig(:github, :client_secret),
    path_prefix: "/users/auth"
end
```

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

If the user is already signed in, the callback links GitHub to that user. It cannot take a provider identity already linked to someone else. Existing users are identified by their provider and provider UID; a matching email alone does not authorize linking.

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

Vouch retains the provider identity while showing that form and creates the user and OAuth link together after valid submission. Provider and UID come from protected session state, not submitted form fields. The continuation expires after `pending_authentication_ttl`.

## Create an organisation during signup

`build_registration(account)` is a controller method you can override to create the records that accompany a new credentials account. Vouch calls it during password registration and immediate OAuth registration.

For example, in a multi-tenant application with `Account`, `User`, and `Organisation`, put the shared implementation in a concern:

```ruby
# app/controllers/concerns/provisions_workspace.rb
module ProvisionsWorkspace
  extend ActiveSupport::Concern

  private

  def build_registration(account)
    organisation = Organisation.create!(name: "#{account.email_address}'s workspace")
    organisation.users.create!(account: account)
  end
end
```

```ruby
# app/controllers/accounts/registrations_controller.rb
class Accounts::RegistrationsController < Vouch::RegistrationsController
  include ProvisionsWorkspace
end

# app/controllers/accounts/omni_auths_controller.rb
class Accounts::OmniAuthsController < Vouch::OmniAuthsController
  include ProvisionsWorkspace
end
```

Both signup methods now create the same initial workspace and membership. The method runs inside the registration transaction and returns the new identity. Use the associations and required fields from your models in its implementation. Invited password registration reuses the existing invitation membership and does not call this method. Deferred OAuth registration currently creates a new account and calls this method; an invitation link alone does not connect it to the invitation. Use the password invitation flow unless you implement that OAuth onboarding integration.

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

Use `--auth-scope` and `--controller-path` for nonstandard names. `--model-only` generates model support without the callback controller, routes, or provider initializer.

## Advanced: retained provider data

A deferred registration retains provider, UID, email, name, and image by default. It does not retain access or refresh tokens. Override `serialize_oauth` and `parse_oauth` together if your flow needs another bounded, serializable representation. Later callbacks receive the reconstructed data rather than the original request's AuthHash.

## Advanced: shared OAuth storage

The default OAuth owner is a concrete model. If several credentials classes share an OAuth table, existing polymorphic ownership is supported:

```ruby
class OauthIdentity < ApplicationRecord
  include Vouch::OAuthIdentity::Concern
  belongs_to :account, polymorphic: true
end

class Account < ApplicationRecord
  has_many :oauth_identities, as: :account, dependent: :destroy
end
```

This requires `account_type` and `account_id` columns. Select nonstandard association names through `associations: { omniauthable: :oauth_identities, oauth_account: :account }` on the credentials scope. Core account/membership and tenant/membership associations remain concrete.
