# Impersonation

Impersonation gives an authorized operator a temporary view of one target identity. It is for support and administrative work where the host application decides both who may act and which records they may enter.

In a single-model `:user` setup, `current_user` is the target and `true_user` is the original operator. In a linked account and membership setup, `current_user` is the target membership while `current_account` remains the operator's account. `current_user.account` is the target membership's associated data; it is not a login for that account.

## Add impersonation

For an existing `:user` scope:

```sh
bin/rails generate vouch:impersonation users
```

The generator creates `Users::ImpersonationsController` and adds `auth.impersonation` to the scope. The generated controller denies every request until the host supplies an authorization rule and a constrained target relation:

```ruby
# app/controllers/users/impersonations_controller.rb
class Users::ImpersonationsController < Vouch::ImpersonationsController
  private

  def authorize_impersonation!
    head :forbidden unless impersonator.support_access?
  end

  def impersonatable_identities
    User.where(organisation_id: impersonator.organisation_ids, global_admin: false)
  end
end
```

`support_access?`, `organisation_ids`, and `global_admin` are host application rules in this example. Vouch finds the submitted target only within `impersonatable_identities`, so the relation is the boundary that prevents an operator from choosing another organisation or another administrator.

An explicitly authorized impersonation does not require the target to complete MFA. If support access needs fresh MFA, add that check to `authorize_impersonation!` using the host application's own policy or predicate on `impersonator`.

## Choose the operator scope

By default, an impersonation controller accepts the scope it serves. Use `impersonator_scopes` when more than one authenticated scope may begin support access:

```ruby
class Users::ImpersonationsController < Vouch::ImpersonationsController
  impersonator_scopes :support_operator, :employee

  private

  def authorize_impersonation!
    head :forbidden unless impersonator.can_support_users?
  end

  def impersonatable_identities
    User.where(organisation_id: impersonator.supported_organisation_ids)
  end
end
```

`impersonator` is the original actor. `impersonator_scope_name` is the resolved source scope. If exactly one allowed scope is authenticated, Vouch selects it automatically. If several are authenticated, the request must supply `impersonator_scope`:

```erb
<%= button_to "View as this user",
  user_impersonate_path(user, impersonator_scope: :support_operator),
  method: :post %>
```

A supplied scope must be allowed by `impersonator_scopes` and authenticated. Otherwise Vouch denies the request. `impersonator_scope :support_operator` remains available as the singular form.

When impersonation is already active, a nested start keeps the original operator and source scope. A nested request cannot select a different original actor.

## Start and stop

```erb
<%= button_to "View as this user", user_impersonate_path(user), method: :post %>
<%= button_to "Stop impersonating", user_stop_impersonation_path, method: :delete %>
```

Vouch supplies `impersonating_user?` in controllers and views.

```erb
<% if impersonating_user? %>
  <p>You are viewing <%= current_user.email_address %>.</p>
  <%= button_to "Return to my account", user_stop_impersonation_path, method: :delete %>
<% end %>
```

| Request | Helper | Action |
| --- | --- | --- |
| `POST /users/impersonations/:id` | `user_impersonate_path(id)` | `Users::ImpersonationsController#create` |
| `DELETE /users/impersonations` | `user_stop_impersonation_path` | `Users::ImpersonationsController#destroy` |
| `DELETE /users/impersonations/all` | `user_stop_all_impersonations_path` | `Users::ImpersonationsController#destroy_all` |

The stack lives in the Rails session. It stores the original operator reference once and records each target by its mapping scope, record key, owner, tenant, and session fingerprint. Those exact references work with ordinary, namespaced, and composite-key models without treating a class name as the identity boundary.

Vouch retains the operator's credential and account sessions. For a membership target it makes only that target membership current; it does not authenticate the target account. Other memberships are unavailable during impersonation, and membership selection routes return `403` until the operator stops. Account endpoints continue to operate on the operator's account.

Nested impersonation uses the same original operator:

```text
Operator → Manager → User
Stop once: return to Manager
Stop all: return to Operator
```

Stopping once restores the previous target. Stopping all restores the original operator. If a stored target reference no longer resolves with its fingerprint, Vouch denies target access until the operator stops; it does not assume an ordinary target login.

## Composite primary keys

Ordinary integer, string, and UUID primary keys work directly in route helpers. When your model has a composite primary key, encode every key component:

```erb
<%= button_to "View as this user", user_impersonate_path(Vouch::RecordKey.to_param(user)), method: :post %>
```

Vouch decodes the parameter inside `impersonatable_identities`. See [primary keys](model-mapping.md#primary-keys).

## Edit the switching actions

```sh
bin/rails generate vouch:eject users impersonations
```

This copies the actions into your controller while preserving its authorization rules. [Ejection](controllers.md#eject-a-controller) explains the shared runtime that remains supplied by Vouch.
