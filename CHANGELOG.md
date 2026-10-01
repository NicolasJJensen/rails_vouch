# Changelog

## Unreleased

- Host-owned registration forms with positional model construction, session continuations, and atomic OAuth, invitation, and MFA persistence.

- Separate MFA challenge, credential-management and recovery-code route declarations with configurable URLs and helper names.
- Documented concrete storage for composite-key recovery-code and password-history owners, and compatible scalar keys for shared polymorphic storage.
- Rails 8.1+ and PostgreSQL support, with case-insensitive email columns.
- Shared password/OAuth sign-in callbacks and customizable action outcomes.
- Mapped writing-connection transactions with rollback detection and preserved errors.
- Selectable signed or opaque password-reset tokens with explicit revocation.
- Account and membership impersonation modes, stable original helpers, and continued-access checks for revoked or expired grants.
- Lossless compact impersonation stacks that retain valid MFA proof across nested restoration.
- Normal and bang operation methods with structured failures and host-controlled responses.
- Optional verification controllers for saved and temporary records, normalized multi-attribute subjects, and shared rate-limit integration.
- Trusted temporary verification export, restoration, and application to an existing record.
- Passwordless sign-in integration and an executable custom credential adapter contract.
- Independent URL segments and named helpers for session and registration routes.
- OAuth registration forms by default, with prefilled provider data and controlled automatic-signup failure redirects.
- Inline migration references and indexes with repeatable feature generation.
- Schema reuse and missing-constraint repair, unloaded model metadata inference, and ejection validation before file writes.
- Foreign-key-selected recovery contact examples with token revocation and captured mail recipients.
- Feature-specific guides with contents, registration flow diagrams, and complete customization examples.
- Password authentication for single-model applications and linked account/membership scopes.
- Generated sign-in, registration, password reset, MFA enrollment, OAuth, invitation, and impersonation endpoints.
- Application controller helpers, named tenant helpers, and controller or shared redirect overrides.
- Authentication session renewal that preserves application data and unrelated logins.
- Lifecycle callbacks with separate transaction callbacks using ActiveHooks.
- Custom scalar and composite primary keys in authentication, tokens, and generated associations.
- Verification subjects composed of one or several attributes.
- Account and credential recovery codes with generated management and sign-in pages.
- An MFA evidence collection for application-owned authentication requirements.
- Nested impersonation with original-operator helpers and cross-scope restoration.
- One-argument scope generation, nested membership routes, and controller ejection that preserves overrides.
- Password history, lockout, reset-token revocation, and explicit session invalidation.
- Task-oriented setup guides, complete route references, and executable integration examples.
