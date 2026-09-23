# Impersonation

Impersonation lets an authorized operator use the application as another user, then return to their own login. Vouch retains the original user while the target becomes `current_user`.

## Add impersonation

For an existing `:user` scope:

```sh
bin/rails generate vouch:impersonation users
```

The generator creates `Users::ImpersonationsController` and adds `auth.impersonation` to the scope. Implement its authorization rule before exposing the action:

```ruby
# app/controllers/users/impersonations_controller.rb
class Users::ImpersonationsController < Vouch::ImpersonationsController
  private

  def authorize_impersonation!
    head :forbidden unless current_user.global_admin?
  end

  def impersonatable_identities
    User.where(global_admin: false)
  end
end
```

Here `global_admin?` is a role check you define, for example through a boolean `global_admin` column. `impersonatable_identities` returns the records the operator may target. Vouch looks up the submitted ID inside that relation, so the example excludes other administrators.

## Start and stop

```erb
<%= button_to "View as this user", user_impersonate_path(Vouch::RecordKey.to_param(user)), method: :post %>
<%= button_to "Stop impersonating", user_stop_impersonation_path, method: :delete %>
```

To display the stop button only during impersonation, define a view helper for your scope:

```ruby
# app/helpers/application_helper.rb
module ApplicationHelper
  def impersonating_user?
    request.env["warden"].user(:user_impersonation).present?
  end
end
```

```erb
<% if impersonating_user? %>
  <p>You are viewing the application as <%= current_user.email_address %>.</p>
  <%= button_to "Return to my account", user_stop_impersonation_path, method: :delete %>
<% end %>
```

The original user is stored under `:user_impersonation`. Stopping restores that user and returns to the saved local page. If their credentials have been revoked, Vouch does not restore the login.

| Request | Helper | Action |
| --- | --- | --- |
| `POST /users/impersonations/:id` | `user_impersonate_path(id)` | `Users::ImpersonationsController#create` |
| `DELETE /users/impersonations` | `user_stop_impersonation_path` | `Users::ImpersonationsController#destroy` |
| `DELETE /users/impersonations/all` | `user_stop_all_impersonations_path` | `Users::ImpersonationsController#destroy_all` |

There is one retained original user, rather than a stack of nested impersonations. Both stop routes restore that original user.

## Impersonate a tenant membership

The same feature works when `:user` is a membership scope linked to `:account`. Starting impersonation switches both the selected membership and its parent account; stopping restores both.

Limit targets to the selected organisation when operators should not cross tenant boundaries:

```ruby
# In Users::ImpersonationsController
 def impersonatable_identities
   current_organisation.users.where(global_admin: false)
 end
```

A global operator may return a broader relation when your authorization rules permit it. Signing out during membership impersonation clears the target account as well as restoration state.

## Separate administrator logins

A `User` with an administrator role can use the flow above. A separate `Admin` authentication scope impersonating a `User` in another scope is not supplied by this feature. That needs a separate implementation for authorization, switching, and restoration; declaring two scopes alone does not connect them.
