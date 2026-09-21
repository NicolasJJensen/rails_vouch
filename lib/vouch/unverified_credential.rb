# frozen_string_literal: true

# Raised by TwoFactorable#enable_two_factor! when called on a credential
# whose Verifiable#verified? is false. Single invariant — 2FA can only be
# enabled on a verified credential.
#
module Vouch
  class UnverifiedCredential < StandardError; end
end
