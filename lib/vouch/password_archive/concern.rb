# frozen_string_literal: true

# Marker concern for password archive models.
#
# Include this in your password archive model so the gem can discover
# the association via reflection at boot.
#
# The host app's model must declare:
#   belongs_to :account
#
# Required columns:
#   account_id, password_digest
#
# Usage:
#   class PasswordArchive < ApplicationRecord
#     include Vouch::PasswordArchive::Concern
#     belongs_to :account
#   end
#
module Vouch
  module PasswordArchive
    module Concern
      extend ActiveSupport::Concern
    end
  end
end
