# Invitations

An invitation lets someone join your application through a link. New users choose their password during registration; existing users sign in with their existing credentials.

## Add invitations

For an existing Vouch `User` model:

```sh
bin/rails generate vouch:invitations User --single-model
bin/rails db:migrate
```

The generator adds invitation fields and associations to `User`, a controller and form, a mailer and template, and invitation routes. It also adds the flag that distinguishes a new invited user awaiting registration from an existing user.

### Decide who can invite

Replace the generated authorization method:

```ruby
# app/controllers/users/invitations_controller.rb
 def authorize_invitation!
   head :forbidden unless current_user.admin?
 end
```

`admin?` is a role check you implement on your model. Without your authorization method, invitations cannot be created.

The generated `build_invited_identity` method finds a user by email or creates one awaiting registration:

```ruby
# In Users::InvitationsController
 def build_invited_identity(identifier)
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

```erb
<%= link_to "Invite someone", new_user_invitation_path %>
```

After the recipient opens the link:

- A new user completes registration and chooses a password. Vouch updates the invited record instead of creating a second user.
- An existing user signs in, including MFA if required. Opening the link alone does not authenticate them or change their password.
- An expired or revoked link returns to sign-in with an error.

## Invite someone to an organisation

For the [multi-tenant setup](model-mapping.md) with `Account`, `User`, and `Organisation`:

```sh
bin/rails generate vouch:invitations User Account
bin/rails db:migrate
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

A new invited account completes registration against the existing invited membership. Vouch does not call `build_registration` to create another organisation. An existing account signs in before accepting its new membership. In both cases, the invitation remains for the organisation that issued it.

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

The generated invitation lookup saves a new credentials record before sending its link. If your model validates profile fields during creation, provide those fields there or make the validations conditional on completed registration. Keep password requirements appropriate to the temporary credential and the final password form.

`registration_required` marks an account awaiting registration; `invitation_registration_required` records that requirement on the invitation. The generator supplies both with non-null false defaults. Do not mark an existing registered account as awaiting registration merely because it receives another invitation.
