# Use an existing Warden manager

Vouch installs Warden middleware during normal setup; you can skip this guide unless your application already manages that middleware. Warden holds authenticated records in named session scopes. Its manager configures which sign-in strategies and failure handler those scopes use. A session scope is a login context, not an Active Record query scope.

## Contents

- [Configure existing middleware](#configure-existing-middleware)
- [Scope ownership](#scope-ownership)
- [Account and membership sessions](#account-and-membership-sessions)

## Configure existing middleware

Disable Vouch's middleware initializer, then edit your existing manager block. Do not add a second Warden middleware entry:

```ruby
# config/initializers/vouch.rb
Vouch.configure do |config|
  config.install_middleware = false
end
```

```ruby
# config/application.rb
module YourApplication
  class Application < Rails::Application
    config.middleware.use Warden::Manager do |manager|
      Vouch.configure_warden(manager)
    end
  end
end
```

`Vouch.configure_warden` accepts a `Warden::Manager` or its configuration object:

- It preserves an existing failure handler; otherwise it installs Vouch's handler.
- It supplies global default strategies only when the manager has none and no Vouch mappings have been registered yet.
- It sets the configured Vouch strategies for credentials scopes and an empty strategy list for membership scopes.
- It applies scope settings to mappings registered later, so your routes do not need special boot-order wiring.

> A shared failure handler must handle failures for every scope it serves. Vouch does not wrap or adapt an existing handler; `Vouch::FailureApp` handles Vouch scopes.

## Scope ownership

Every Vouch mapping reserves its primary scope and the derived account and
impersonation scopes. For example, `:user` reserves `:user`,
`:user_account`, and `:user_impersonation`. Vouch rejects overlaps between
these reserved names across mappings. The strategy name `:password` is also
reserved by Vouch's password strategy.

Vouch registers serializers for these scopes when the route mapping is built.
The identity and account serializers store a record key plus an authentication
fingerprint used to reject sessions after credentials or session-version changes. Restoration reloads the current model class, checks the
fingerprint, and rejects locked accounts when session invalidation on lockout
is enabled. A membership also requires its parent account scope to identify
the same account.

Leave serialization and Warden authentication mechanisms for Vouch-owned scopes to Vouch. Customize admission through the supported [authentication policy](authentication-policy.md) instead. If another application component owns a separate Warden scope, choose
a non-overlapping name and keep its serializer independent.

## Account and membership sessions

An account login and its membership selections are separate Warden scopes. Vouch restores an ordinary membership only when its owning account is authenticated. Membership-only impersonation is an explicitly restricted exception: it authorizes the selected target membership without signing in as that membership’s account. Full account impersonation may select memberships of the target account; see [impersonation](impersonation.md) for the permission and restoration rules. The [scope reference](model-mapping.md#shared-account-scopes) describes how to declare these relationships.
