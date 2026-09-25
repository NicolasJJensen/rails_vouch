# Changelog

## Unreleased

- Password authentication for single-model applications and linked account/membership scopes.
- Generated sign-in, registration, password reset, MFA enrollment, OAuth, invitation, and impersonation endpoints.
- Application controller helpers, named tenant helpers, and controller or shared redirect overrides.
- Authentication session renewal that preserves application data and unrelated logins.
- Lifecycle callbacks with separate transaction callbacks using ActiveHooks.
- Custom scalar and composite primary keys in authentication, tokens, and generated associations.
- Verification subjects composed of one or several attributes.
- Account and credential recovery codes with generated management and sign-in pages.
- Organisation-specific MFA policies with recorded authentication evidence.
- Nested impersonation with original-operator helpers and cross-scope restoration.
- One-argument scope generation, nested membership routes, and controller ejection that preserves overrides.
- Password history, lockout, reset-token revocation, and explicit session invalidation.
- Task-oriented setup guides, complete route references, and executable integration examples.
