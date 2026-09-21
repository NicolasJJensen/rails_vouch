# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class LockableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "lockable"
      desc "Add lockable columns to the account table."
    end
  end
end
