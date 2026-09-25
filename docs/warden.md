# Warden integration

Vouch installs Warden middleware by default. Use this guide when your application
already owns Warden middleware or needs to configure its defaults explicitly.
See [model mapping](model-mapping.md) for scope definitions.

## Configure existing middleware

Disable Vouch's middleware initializer and configure the manager in your application's
middleware stack:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.install_middleware = false
  config.warden_default_strategies = [:password]
  config.warden_failure_app = Vouch::FailureApp
end
```

```ruby
# config/application.rb
config.middleware.use Warden::Manager do |manager|
  Vouch.configure_warden(manager)
end
```

`Vouch.configure_warden` accepts a `Warden::Manager` or its config object. It
sets the failure app when your application has not already supplied one, applies the
default strategy only when the manager has no defaults, and adds Vouch's
strategy defaults to each registered scope. Existing application defaults remain in
place.

If your application already has a manager block, call `Vouch.configure_warden(manager)`
inside that block instead of adding a second Warden middleware entry.

## Scope ownership

Every Vouch mapping reserves its primary scope and the derived account and
impersonation scopes. For example, `:user` reserves `:user`,
`:user_account`, and `:user_impersonation`. Vouch rejects overlaps between
these reserved names across mappings. The strategy name `:password` is also
reserved by Vouch's password strategy.

Vouch registers serializers for these scopes when the route mapping is built.
The identity and account serializers store a record key plus an authentication
fingerprint. Restoration reloads the current model class, checks the
fingerprint, and rejects locked accounts when session invalidation on lockout
is enabled. A membership also requires its parent account scope to identify
the same account.

Do not register a second serializer or authentication policy for a Vouch-owned
scope. If another application component owns a separate Warden scope, choose
a non-overlapping name and keep its serializer independent.

## Account and membership sessions

An account login and its membership selections are separate Warden scopes. Vouch restores a membership only when its owning account is authenticated and its authentication requirements remain satisfied. The [scope reference](model-mapping.md#shared-account-scopes) describes how to declare these relationships.
