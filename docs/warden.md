# Existing Warden integration

Use this guide when Vouch is added to an existing Warden stack. See [model mapping](model-mapping.md) and the [README](../README.md).

## Middleware and scopes

Disable installation and configure the existing manager explicitly:

```ruby
Vouch.configure { |config| config.install_middleware = false }
# In the host's existing Warden configuration block:
Vouch.configure_warden(manager)
```

A `:member` mapping reserves Warden scopes `:member`, `:member_account`, and `:member_impersonation` for authenticated identity, pending account, and restoration identity. Every mapping follows the same naming rule. `:password` is also reserved as a strategy name.

Vouch rejects collisions between its mappings and derived scopes. Choose mapping names that do not overlap host scopes. Other gems must not register different serializers or authentication behavior for these reserved scopes; the host coordinates that integration.

Vouch applies its strategies to registered scopes, preserves supplied host defaults and failure handling, and uses Warden directly. It does not install `rails_warden` monkey patches. Configure the host failure app to route Vouch scope failures appropriately.
