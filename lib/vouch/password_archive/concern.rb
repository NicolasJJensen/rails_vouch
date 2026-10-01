# frozen_string_literal: true

# Marker concern for password archive models.
#
# Include this in your password archive model so the gem can discover
# the association via reflection at boot.
#
# The host supplies the owner association. Its name and foreign keys follow
# that model; the feature discovers the owner's has_many association.
# Archive rows require password_digest and created_at columns.
#
# Usage:
#   class PasswordArchive < ApplicationRecord
#     include Vouch::PasswordArchive::Concern
#     belongs_to :user
#   end
#
module Vouch
  module PasswordArchive
    module Concern
      extend ActiveSupport::Concern
    end
  end
end
