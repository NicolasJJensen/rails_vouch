# Changelog

All notable changes are recorded here. These entries describe unreleased work and are intentionally not assigned a release date or version.

## [Unreleased]

### Added

- Account-first authentication scopes with separate account and membership sessions.
- Account login, MFA, membership selection, and independent logout semantics.
- `Vouch::MembershipSessionsController` for membership authentication and `Vouch::SessionsController` for account authentication.
- Shared host redirect hooks receiving the authenticated identity and scope.
- Password-reset generator wiring for the model feature, routes, mailer hook, and explicit reset-token revocation.

### Changed

- Gem endpoint controllers inherit `ApplicationController` and include `Vouch::Authentication`; generated application controllers subclass those endpoints.
- The public API no longer uses `Vouch::BaseController`, `parent_controller`, `authentication_callbacks`, or the `--concrete` generator option.
- Split scopes use `account_scope:` with `identity:` and optional `tenant:`; tenant is not inferred from a login scope.
- Guides now explain complete setup flows, route helpers, redirect precedence, account/membership ownership, and reset-token revocation.
