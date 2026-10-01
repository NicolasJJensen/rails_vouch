# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class TokenVerifiableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "token_verifiable"
      desc "Add signed-link verification to an existing model."
      class_option :subject, type: :array, default: []

      def configure_model
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)

        contents = File.read(path)
        wiring = +"\n"
        wiring << "  include Vouch::TokenVerifiable::Concern\n" unless contents.include?("include Vouch::TokenVerifiable::Concern")
        if options[:subject].any? && !contents.include?("verifiable_subject_attribute")
          attributes = options[:subject].map do |name|
            raise Thor::Error, "Invalid subject attribute" unless name.match?(/\A[a-z_][a-z0-9_]*\z/)
            name.to_sym
          end
          value = attributes.one? ? attributes.first.inspect : attributes.inspect
          wiring << "  self.verifiable_subject_attribute = #{value}\n"
        end
        inject_model_code(path, model_metadata, wiring) unless wiring == "\n"
      end
    end
  end
end
