# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class TokenVerifiableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "token_verifiable"
      desc "Add TokenVerifiable columns to a model's table."
    end
  end
end
