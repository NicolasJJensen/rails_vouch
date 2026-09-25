# Invitations

An invitation lets someone join your application through a link. In a multi-tenant application, they can join an organisation with an existing account or register a new account.

## Add invitations

For an existing Vouch `User` model:

```sh
bin/rails generate vouch:invitations User
bin/rails db:migrate
```

The generator adds invitation fields and associations to `User`, a controller and form, a mailer and template, and invitation routes. The invitation is stored on the `User` record, not a separate invitations table. The migration adds:

```ruby
add_column :users, :invitation_token, :string
add_column :users, :invitation_sent_at, :datetime
add_column :users, :invitation_accepted_at, :datetime
add_column :users, :inviter_id, :bigint
add_index :users, :invitation_token, unique: true
add_index :users, :inviter_id
add_foreign_key :users, :users, column: :inviter_id
add_column :users, :registration_required, :boolean, default: false, null: false
```

`registration_required` distinguishes a newly invited person who still needs to choose a password from someone who already completed registration.

### Decide who can invite

Replace the generated authorization method:

```ruby
# app/controllers/users/invitations_controller.rb
 def authorize_invitation!
   head :forbidden unless current_user.admin?
 end
```

`authorize_invitation!` runs as a `before_action` on `create`. The example uses your own `admin?` role predicate. The default method denies creation until you replace it. Acceptance validates the invitation and account; revocation uses the relation described below.

For single-tenant authentication, the generated `build_invited_account` method finds a `User` by email or creates one awaiting registration:

```ruby
# In Users::InvitationsController
 def build_invited_account(identifier)
   email = identifier.to_s.strip.downcase
   User.find_by("LOWER(email_address) = ?", email) || User.create!(
     email_address: email,
     registration_required: true,
     password: SecureRandom.base64(48).truncate_bytes(64)
   )
 end
```

Customize this method if your model requires additional fields or uses another login identifier. The temporary random password is replaced when the new user accepts and completes registration. Existing users keep their password.

### Customize delivery

The generated controller connects the invitation event to the mailer:

```ruby
# In Users::InvitationsController
 on_invitation_token_generation do |identifier, invitation|
   VouchInvitationMailer.invitation(identifier, invitation).deliver_later
 end
```

Edit the generated mailer and template to change the message:

```ruby
# app/mailers/vouch_invitation_mailer.rb
class VouchInvitationMailer < ApplicationMailer
  def invitation(identifier, invitation)
    @invitee = invitation
    mail(to: identifier, subject: "Join our application")
  end
end
```

```erb
<%# app/views/vouch_invitation_mailer/invitation.text.erb %>
Accept your invitation: <%= accept_user_invitation_url(token: @invitee.invitation_token) %>
```

The link uses your Action Mailer URL configuration.

### Offer the invitation form

The generator supplies `app/controllers/users/invitations_controller.rb` and `app/views/users/invitations/new.html.erb`. Link to that generated form:

```erb
<%= link_to "Invite someone", new_user_invitation_path %>
```

After the recipient opens the link:

- A new user completes registration and chooses a password. Vouch updates the invited record instead of creating a second user.
- An existing user accepts using their account. If that account is already signed in, Vouch reuses its session; otherwise they sign in and complete required MFA. Their password is unchanged.
- An expired or revoked link returns to sign-in with an error.

## Invite someone to an organisation

For the [multi-tenant setup](model-mapping.md) with `Account`, `User`, and `Organisation`:

```sh
bin/rails generate vouch:invitations User --account Account
bin/rails db:migrate
```

The generator normally infers the account from the configured `User` mapping. `--account Account` explicitly selects it when needed.

The invitation fields and inviter relationship shown above are added to `users`. The registration flag instead belongs to `accounts`:

```ruby
add_column :accounts, :registration_required, :boolean, default: false, null: false
```

The invitation is attached to the `User` membership. The generated lookup finds or creates its credentials `Account`, and Vouch creates the membership in the inviter's organisation. The `:user` scope contains `auth.invitations`; account registration remains on the parent scope:

```ruby
Vouch.routes(self) do |auth|
  auth.scope :account, model: "Account" do
    auth.sessions
    auth.registrations
  end
  auth.scope :user, account_scope: :account, identity: "User", tenant: "Organisation" do
    auth.sessions
    auth.invitations
  end
end
```

A new account chooses its password while retaining the invited membership and its organisation. An existing account accepts that membership using its existing login. Neither path creates another organisation.

Invitation acceptance and registration have [transactional hooks](#registration-customization) for accompanying records. Pending memberships are not ordinary sign-in choices: Vouch requires their valid invitation before granting access.

Tenant assignment is automatic through the configured associations. Override `assign_tenant_to_invitee(identity, inviter)` only when your invitation policy needs different assignment rules.

## Revoke an invitation

```erb
<%= button_to "Revoke invitation", user_invitation_path, method: :delete,
  params: { invitation_token: invitation.invitation_token } %>
```

By default, a user may revoke their own pending invitations, within the selected organisation when applicable. Override `revocable_invitations` to return another authorized relation, for example to let an organisation administrator revoke invitations from colleagues:

```ruby
# In Users::InvitationsController
 def revocable_invitations
   return super unless current_user.admin?

   current_organisation.users.pending_invitation
 end
```

Revocation removes the invited membership in a multi-tenant setup. For a single-model user, it clears the invitation without deleting the user record.

## Routes

| Request | Helper | Action |
| --- | --- | --- |
| `GET /users/invitation/new` | `new_user_invitation_path` | `Users::InvitationsController#new` |
| `POST /users/invitation` | `user_invitation_path` | `Users::InvitationsController#create` |
| `GET /users/invitation/accept?token=…` | `accept_user_invitation_path(token: token)` | `Users::InvitationsController#accept` |
| `DELETE /users/invitation` | `user_invitation_path` | `Users::InvitationsController#destroy` |

## Registration customization

`registration_required: true` means the credentials account has not finished registration. Accepting an invitation and choosing a password clears that flag. Other invitations for the same account then use its existing login, rather than asking for another password.

Use registration hooks for account-wide records and invitation-acceptance hooks for membership records:

```ruby
# In the generated registrations controller
 after_sign_up do |account, identity|
   Preferences.create!(account: account)
 end
```

```ruby
# In a concern included by the authentication controllers completing acceptance
 on_invitation_acceptance do |identity, account|
   MembershipPreferences.create!(user: identity)
 end
```

`Preferences` and `MembershipPreferences` are example models you supply. These callbacks run inside their operation's database transaction. Use [post-commit hooks](sessions-and-hooks.md#lifecycle-hooks) for external effects.

The generated lookup saves a pending account before sending its invitation. If your account requires profile fields at creation, supply them in `build_invited_account` or condition those validations on completed registration.

## Edit the invitation actions

```sh
bin/rails generate vouch:eject users invitations
```

The endpoint actions become editable in your controller. Your existing lookup and authorization overrides remain in place. See [ejection](controllers.md#eject-a-controller).
