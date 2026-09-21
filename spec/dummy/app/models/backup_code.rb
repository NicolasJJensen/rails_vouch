# frozen_string_literal: true

# Dummy host for the BackupCodable concern. The parent TwoFactorCredential
# has_many :backup_codes; a BCrypt-hashed code_digest and a used_at
# timestamp make each row single-use.
class BackupCode < ApplicationRecord
  belongs_to :two_factor_credential
end
