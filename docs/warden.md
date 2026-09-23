# Existing Warden integration

Use this guide when Vouch is added to an existing Warden stack. See [model mapping](model-mapping.md) and the [README](../README.md).

## Middleware and scopes

Disable installation and configure the existing manager explicitly:

```ruby
Vouch.configure { |config| config.install_middleware = false }
# In the host's existing Warden configuration block:
Vouch.configure_warden(manager)
```

A mapping reserves its primary name and derived account/impersonation names to prevent collisions. Combined mappings use the derived account scope for pending selection. Linked membership mappings instead reference their explicitly configured parent account session and use their own primary scope for the selected membership. `:password` is also reserved as a strategy name.

Vouch rejects collisions between its mappings and derived scopes. Choose mapping names that do not overlap host scopes. Other gems must not register different serializers or authentication behavior for these reserved scopes; the host coordinates that integration.

Vouch applies its strategies to registered scopes, preserves supplied host defaults and failure handling, and uses Warden directly. It does not install `rails_warden` monkey patches. Configure the host failure app to route Vouch scope failures appropriately.

## Linked scopes

A linked membership scope references its parent credentials scope with `account_scope:`. Password strategies run on the credentials scope, not the membership scope. Restoring a membership also requires a valid parent session belonging to the same account. Account sign-out invalidates dependent memberships. Membership rotation retains the parent and sibling memberships automatically.
