# Impersonation

Impersonation lets an authorized operator use the application as another user, then return to their own login. `true_user` identifies the original operator while `current_user` becomes the person being impersonated. Outside impersonation both return the signed-in user.

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
    head :forbidden unless true_user.global_admin?
  end

  def impersonatable_identities
    User.where(global_admin: false)
  end
end
```

Here `global_admin?` is a role check you define, for example through a boolean `global_admin` column. `impersonatable_identities` returns the records the operator may target. Vouch looks up the submitted ID inside that relation, so the example excludes other administrators.

## Start and stop

```erb
<%= button_to "View as this user", user_impersonate_path(user), method: :post %>
<%= button_to "Stop impersonating", user_stop_impersonation_path, method: :delete %>
```

Vouch supplies `impersonating_user?` in controllers and views:

```erb
<% if impersonating_user? %>
  <p>You are viewing the application as <%= current_user.email_address %>.</p>
  <%= button_to "Return to my account", user_stop_impersonation_path, method: :delete %>
<% end %>
```

Starting impersonation saves the previous authentication context and local return page on a stack. Stopping restores the previous context. If its account credentials were revoked, Vouch does not restore that login.

| Request | Helper | Action |
| --- | --- | --- |
| `POST /users/impersonations/:id` | `user_impersonate_path(id)` | `Users::ImpersonationsController#create` |
| `DELETE /users/impersonations` | `user_stop_impersonation_path` | `Users::ImpersonationsController#destroy` |
| `DELETE /users/impersonations/all` | `user_stop_all_impersonations_path` | `Users::ImpersonationsController#destroy_all` |

Nested impersonation uses a stack:

```text
Operator → Manager → User
Stop once: return to Manager
Stop all: return to Operator
```

`true_user` continues to identify Operator throughout. `user_stop_all_impersonations_path` ends the entire stack.

## Multi-tenant applications

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

For an administrator authenticated through a separate `:admin` scope, configure that source on the target's controller:

```ruby
class Users::ImpersonationsController < Vouch::ImpersonationsController
  impersonator_scope :admin

  private

  def authorize_impersonation!
    head :forbidden unless true_admin.support_access?
  end

  def impersonatable_identities
    User.where(suspended: false)
  end
end
```

`support_access?` and `suspended` are application rules in this example. `true_admin` remains the original operator, while `current_user` is the target. Stopping restores the originating scope and its authentication context.

## Composite primary keys

Ordinary integer, string and UUID primary keys use the record directly in route helpers. When your model has a composite primary key, use Vouch's encoding:

```erb
<%= button_to "View as this user", user_impersonate_path(Vouch::RecordKey.to_param(user)), method: :post %>
```

The encoded parameter carries every key component; Vouch decodes it within the authorized target relation. See [primary keys](model-mapping.md#primary-keys).

## Edit the switching actions

```sh
bin/rails generate vouch:eject users impersonations
```

This copies the actions into your controller while preserving its authorization rules. [Ejection](controllers.md#eject-a-controller) explains the shared runtime that remains supplied by Vouch.
