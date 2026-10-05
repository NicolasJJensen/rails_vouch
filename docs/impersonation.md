# Impersonation

Impersonation gives an authorized operator a temporary view of one target identity. It is for support and administrative work where the host application decides both who may act and which records they may enter.

In a single-model `:user` setup, `current_user` is the target and `true_user` is the original operator. A multi-tenant application can impersonate either a membership or the account that signs in:

| Operation | `current_user` | `current_account` |
| --- | --- | --- |
| Impersonate a membership | Target membership | Account authorized before the switch |
| Impersonate an account | `nil` until selecting a membership | Target account |
| Select a membership while impersonating an account | Selected membership of that account | Target account |

`true_user` and `true_account` retain their original signed-in values throughout the chain. A scope that was not signed in originally returns `nil`. Names follow your authentication scopes.

> During membership impersonation, `current_user.account` is the target membership's associated data; it does not grant authentication as that account. Account settings should use `current_account` for the effective authorized account, or `true_account` for a deliberately personal settings page. Your permissions still govern writes through ordinary associations.

## Contents

- [Add impersonation](#add-impersonation)
- [Start and stop](#start-and-stop)
- [Expire or revoke impersonation access](#expire-or-revoke-impersonation-access)
- [Choose the operator scope](#choose-the-operator-scope)
- [Composite primary keys](#composite-primary-keys)
- [Edit the switching actions](#edit-the-switching-actions)
- [Customize action responses](#customize-action-responses)

## Add impersonation

For an existing `:user` scope:

```sh
bin/rails generate vouch:impersonation users
```

The generator creates `Users::ImpersonationsController` and adds `auth.impersonation` to the scope. Add your application’s permission check to the generated action. Vouch prepares `@user` before the action runs (a custom scope uses its own name):

```ruby
# app/controllers/users/impersonations_controller.rb
class Users::ImpersonationsController < Vouch::ImpersonationsController
  def create
    # Authorize impersonator's access to @user here.
    return head :forbidden unless impersonator.support_access?

    super
  end

  private

  def impersonatable_identities
    User.where(organisation_id: impersonator.organisation_ids, global_admin: false)
  end
end
```

`support_access?`, `organisation_ids`, and `global_admin` are host application rules in this example. Vouch finds the submitted target only within `impersonatable_identities`, so the relation is the boundary that prevents an operator from choosing another organisation or another administrator.

> Permission checks belong to your application. The generated comment does not enforce authorization. Use your normal action override or authorization callbacks before switching identities.

`set_identity` looks up the target through `impersonatable_identities` before `create`. A missing target raises `ActiveRecord::RecordNotFound`, which Rails handles as a not-found response; your application can use its normal `rescue_from` handling. Permission exceptions also propagate normally.

An explicitly authorized impersonation does not require the target to complete MFA. If support access needs fresh MFA, add that check to your `create` action before `super` using the host application's own policy or predicate on `impersonator`.

## Start and stop

```erb
<%= button_to "View as this user", user_impersonate_path(user), method: :post %>
<%= button_to "Stop impersonating", user_stop_impersonation_path, method: :delete %>
<%= button_to "Stop all impersonation", user_stop_all_impersonations_path, method: :delete %>
```

Vouch supplies `impersonating_user?` in controllers and views. It identifies participation in the chain. When rendering a scope-specific stop button, check that scope is the current target:

```erb
<% if impersonation_context&.target_scope == :user %>
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

Membership impersonation retains the account authorized immediately before that switch. Ordinary membership selection returns `403` while this restriction applies. Full account impersonation clears existing memberships and permits selecting the target account's memberships; account settings operate on that target account subject to your permissions.

For example, support account A impersonates account B, selects B's membership, then impersonates membership C. At that point `current_user` is C's membership, `current_account` is B, and `true_account` is A. Account C is never signed in. Stopping once returns to B's selected membership.

Stopping a nested impersonation restores the preceding context:

```text
Operator → Manager → User
Stop once: return to Manager
Stop all: return to Operator
```

Stopping once restores the previous target. Stopping all restores the original signed-in context. The `impersonation_end` hooks and action result identify the record being restored. A changed password, revoked session or reassigned membership invalidates its saved reference; Vouch removes that impersonation and dependent steps before serving another target page.

## Expire or revoke impersonation access

Applications that require approval can keep grants in their own database and check them on every request. Vouch does not generate approval records, requests, emails or approval pages.

For example, an account owner could approve a support operator until a particular time:

```ruby
# app/models/impersonation_grant.rb
class ImpersonationGrant < ApplicationRecord
  belongs_to :operator, class_name: "Account"
  belongs_to :account

  scope :active, -> {
    where.not(approved_at: nil).where(revoked_at: nil)
      .where("expires_at > ?", Time.current)
  }
end
```

> This example assumes your application supplies this model and its fields. Your permissions determine who can request, approve and revoke a grant.

Put the continued-access check in your common controller so it also runs on ordinary application pages:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  private

  def impersonation_allowed?(context)
    return true unless context.mode == :account

    ImpersonationGrant.active.exists?(operator: context.operator, account: context.target)
  end

  def after_impersonation_expired_path
    root_path
  end
end
```

Use the same permission rule when authorizing `create`; this check governs subsequent requests. It defaults to `true` when you do not override it. `context` supplies `mode`, `operator`, `target`, `operator_scope` and `target_scope`; the public `impersonation_context` helper returns the current context, or `nil` outside impersonation. It does not replace `true_*` helpers: the operator for a nested switch can differ from the original signed-in person.

Before an action runs, Vouch checks every step in order. A `false` result removes that step and everything after it, restores the preceding authorized context, and redirects with an explanation. If the original login is no longer valid, its sessions are cleared. A permission-check exception propagates through your normal Rails error handling. Saved MFA proof is restored only for its own account; current proof validation still applies. Explicit sign-out still ends the participating sessions, and stop-all still removes the entire chain, even if a grant expired immediately before that request.

## Choose the operator scope

By default, an impersonation controller accepts the scope it serves. Use `impersonator_scopes` when more than one authenticated scope may begin support access:

```ruby
# app/controllers/users/impersonations_controller.rb
class Users::ImpersonationsController < Vouch::ImpersonationsController
  impersonator_scopes :support_operator, :employee

  def create
    return head :forbidden unless impersonator.can_support_users?

    super
  end

  private

  def impersonatable_identities
    User.where(organisation_id: impersonator.supported_organisation_ids)
  end
end
```

`impersonator` is the actor authorizing this switch. A membership-only chain retains its first authorizing actor; selecting a membership during full account impersonation allows that membership to authorize a subsequent membership switch. `impersonator_scope_name` is the resolved source scope. If exactly one allowed scope is authenticated, Vouch selects it automatically. If several are authenticated, the request must supply `impersonator_scope`:

```erb
<%= button_to "View as this user",
  user_impersonate_path(user, impersonator_scope: :support_operator),
  method: :post %>
```

A supplied scope must be allowed by `impersonator_scopes` and authenticated. An unknown, disallowed or unauthenticated supplied scope returns `403 Forbidden`. If several allowed scopes are authenticated and none is supplied, the response is `422 Unprocessable Content` with “Choose an impersonator_scope”. `impersonator_scope :support_operator` remains available as the singular form.

Once a membership-only chain starts, nested requests cannot change its authorizing actor or escalate to account impersonation. The `true_*` helpers always retain the original signed-in context.

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

## Customize action responses

The switching actions return `:ok`, `:cancelled`, or `:invalid` from `super`. Put authorization before `super`, then choose your response afterward. The configured identity is exposed as `@user` in a user scope or `@account` in an account scope; a custom scope uses its own name.

```ruby
# app/controllers/users/impersonations_controller.rb
class Users::ImpersonationsController < Vouch::ImpersonationsController
  def create
    # Authorize impersonator's access to @user here.
    status = super
    return unless request.format.json?

    render json: { status: status }, status: status == :ok ? :ok : :unprocessable_content
  end
end
```

Use the same pattern in `destroy` or `destroy_all` to customize one-level or complete restoration. After either stop action, the scoped record variable contains the identity currently signed into that scope, or `nil` if restoration left it signed out. A cancelled stop keeps the current target; a cancelled `create` keeps the attempted target available for error handling. A lifecycle cancellation returns `:cancelled`; invalid restoration returns `:invalid` with `@failure_reason == :invalid_impersonation`. If your action does not render, redirect, or call `head`, Vouch's `default_render` supplies the default response after the action finishes. Record lookup and authentication filters run before the action, so their failures use normal Rails response handling.
