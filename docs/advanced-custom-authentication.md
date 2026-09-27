# Advanced custom authentication

## Contents

- [When to use this API](#when-to-use-this-api)
- [Complete a verified proof](#complete-a-verified-proof)
- [Handle outcomes](#handle-outcomes)

## When to use this API

Use this only after a host endpoint has independently verified a first-factor proof, such as a passwordless code or hardware credential. Generated password, OAuth, registration, and MFA endpoints already verify their proof and complete authentication.

## Complete a verified proof

After verification, call the controller completion API with the credentials account. Never trust an account ID from a browser as the proof. This unauthenticated example looks up a persisted phone by the submitted contact value, issues and delivers its code through the model, and keeps only the credential reference and opaque OTP token in the Rails session. `SmsService` is host application code.

Start by adding the concern and its required schema to a persisted credential model:

```sh
bin/rails generate vouch:magic_linkable Phone
bin/rails db:migrate
```

The migration adds:

```ruby
change_table :phones do |t|
  t.string :sign_in_nonce
  t.bigint :sign_in_attempts, default: 0, null: false
  t.datetime :sign_in_locked_at
end
``` The credential needs a concrete owner association, normalized contact data, and an index/validation appropriate to the application’s uniqueness rule. A phone used as a unique login identifier normally has a unique index:

```ruby
change_table :phones do |t|
  t.index :e164, unique: true
end
```

```ruby
# app/controllers/users/passwordless_sessions_controller.rb
class Users::PasswordlessSessionsController < ApplicationController
  include Vouch::Authentication
  auth_scope :user

  def new
  end

  def create_code
    phone = Phone.find_by(e164: params.require(:e164).to_s.strip)
    return render(:new, status: :unprocessable_entity) unless phone

    result = phone.issue_sign_in_code!

    if result.ok?
      session[:passwordless_phone_id] = phone.id
      session[:passwordless_code_token] = result.token
      redirect_to verify_users_passwordless_sessions_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  def verify
  end

  def create
    phone = Phone.find_by(id: session[:passwordless_phone_id])
    result = phone&.verify_sign_in_code(
      params.require(:code), token: session[:passwordless_code_token]
    )
    return render(:verify, status: :unprocessable_entity) unless result&.ok?

    # Resolve the account through the verified record, not params[:user_id].
    account = phone.user
    session.delete(:passwordless_phone_id)
    session.delete(:passwordless_code_token)
    complete_verified_passwordless_sign_in(account, phone)
  end

  private

  def complete_verified_passwordless_sign_in(account, phone)
    outcome = complete_sign_in(account, method: :passwordless,
      hook: :sign_in, signed_in_via: phone)

    case outcome
    when :signed_in
      redirect_after_authentication
    when :needs_two_factor
      redirect_to two_factor_challenges_path
    when :needs_selection
      redirect_to select_path
    when :no_identity, :denied
      redirect_to new_user_session_path, alert: "Unable to sign in"
    end
  end
end
```

The `Phone` model supplies delivery; do not deliver a second code in the controller:

```ruby
class Phone < ApplicationRecord
  include Vouch::MagicLinkable
  belongs_to :user

  normalizes :e164, with: ->(value) { value.to_s.strip }
  validates :e164, presence: true, uniqueness: true

  def deliver_sign_in_code(code)
    SmsService.deliver(e164, "Your sign-in code is #{code}")
  end
end
```

Add host routes for the request, issuance, and verification pages:

```ruby
namespace :users do
  resources :passwordless_sessions, only: [:new, :create] do
    collection do
      post :create_code
      get :verify
    end
  end
end
```

The proof verification must happen before `complete_sign_in`. That method applies policy, MFA, session rotation, Warden publication, membership selection, and lifecycle hooks; it does not verify a raw password, code, or provider response for you.

`issue_sign_in_code!` delivers the code and returns `Result.ok(token)`. `verify_sign_in_code` consumes that token under a credential lock and clears the nonce after success, so replaying the same code/token returns an invalid result. A new issue also replaces the nonce, invalidating the prior challenge.

The request form submits the contact value. It does not submit a user ID:

```erb
<%# app/views/users/passwordless_sessions/new.html.erb %>
<%= form_with url: create_code_users_passwordless_sessions_path do |form| %>
  <%= form.label :e164, "Mobile number" %>
  <%= form.telephone_field :e164, autocomplete: "tel", required: true %>
  <%= form.submit "Send code" %>
<% end %>
```

The verification form posts only the code; the Rails session holds the short-lived verification token and credential reference:

```erb
<%# app/views/users/passwordless_sessions/verify.html.erb %>
<%= form_with url: users_passwordless_sessions_path do |form| %>
  <%= form.label :code, "Code" %>
  <%= form.text_field :code, autocomplete: "one-time-code", required: true %>
  <%= form.submit "Sign in" %>
<% end %>
```

## Handle outcomes

| Outcome | Host endpoint action |
| --- | --- |
| `:signed_in` | Redirect through `redirect_after_authentication`. |
| `:needs_two_factor` | Redirect to the supplied MFA challenge. |
| `:needs_selection` | Redirect to membership selection. |
| `:no_identity` or `:denied` | Clear pending references and show a safe failure response. |

For a full custom controller, eject the nearest supplied endpoint first so its scope, route helpers, and failure handling remain visible. A custom Warden strategy needs a name other than Vouch’s reserved `:password` strategy.
