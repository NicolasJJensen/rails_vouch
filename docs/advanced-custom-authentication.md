# Advanced custom authentication

Use `complete_sign_in` only when your application implements a first-factor sign-in method that Vouch does not supply. It connects an already verified credentials record to Vouch's MFA, membership selection and session lifecycle. It does not verify a password, code or provider response itself.

For ordinary integrations, use the supplied [password sign-in](../README.md), [OAuth](oauth.md) or [passwordless credential APIs](passwordless.md) instead.

## Contents

- [Verify proof before completing sign-in](#verify-proof-before-completing-sign-in)
- [Handle completion outcomes](#handle-completion-outcomes)
- [Preserve the authentication boundary](#preserve-the-authentication-boundary)

## Verify proof before completing sign-in

For a custom hardware sign-in method, your verifier must check the challenge, signature, expiry and replay protection and return the verified credentials record. The browser must not be allowed to select that record just by submitting its ID.

The following integration assumes you implement `HardwareSignIn.verify` in your application. Its return value is a `User` whose proof it accepted, or `nil`. It is not a Vouch class or a complete hardware-verification implementation.

```ruby
# app/controllers/users/hardware_sessions_controller.rb
class Users::HardwareSessionsController < Vouch::SessionsController
  def create
    user = HardwareSignIn.verify(
      challenge: session.delete(:hardware_sign_in_challenge),
      assertion: params.require(:assertion)
    )
    return redirect_to(new_session_path, alert: "Unable to sign in") unless user

    case complete_sign_in(user, method: :hardware, hook: :sign_in)
    when :signed_in
      redirect_after_authentication
    when :needs_two_factor
      redirect_to two_factor_challenges_path
    when :needs_selection
      redirect_to select_path
    else
      redirect_to new_session_path, alert: "Unable to sign in"
    end
  end
end
```

Add the endpoint beside your existing Vouch routes:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  Vouch.routes(self) do |auth|
    auth.scope model: "User" do
      auth.sessions
      auth.registrations
    end
  end

  post "users/hardware_sign_in", to: "users/hardware_sessions#create"
end
```

Your application supplies the challenge-issuance endpoint and browser integration for its hardware verifier. For a complete phone-code example, follow [passwordless sign-in](passwordless.md); its credential model supplies issuance and proof consumption.

In a multi-tenant application, pass the model containing credentials, such as `Account`. Membership selection follows account authentication; a submitted membership ID is not first-factor proof.

## Handle completion outcomes

| Outcome | What your endpoint does |
| --- | --- |
| `:signed_in` | Redirect with `redirect_after_authentication`. |
| `:needs_two_factor` | Redirect to `two_factor_challenges_path`. The session is not fully authenticated yet. |
| `:needs_selection` | Redirect to `select_path` to choose a membership. |
| Other outcomes, including `:no_identity` and `:denied` | Show a failure response; do not publish a Warden identity yourself. |

The completion method runs the normal `sign_in` lifecycle with `authentication_method: :hardware` in this example. Put callbacks shared with other sign-in methods in your [application parent controller](sessions-and-hooks.md#share-sign-in-callbacks).

## Preserve the authentication boundary

- Verify and consume first-factor proof before calling completion. Never convert an ordinary contact verification into MFA evidence.
- Start completion outside an existing transaction on the credentials model's writing connection. Add related database work through lifecycle callbacks.
- Keep the exact primary credential reference when your flow supports it, so the same credential cannot satisfy both passwordless sign-in and its required MFA challenge.
- Treat a pending outcome as a continuation, not a completed login. Let the supplied MFA and membership controllers finish it.

Use [controller ejection](controllers.md#eject-a-controller) when you need to own a supplied endpoint's implementation. Ejection retains the shared Vouch runtime; it does not turn an unchecked account ID into authenticated proof.
