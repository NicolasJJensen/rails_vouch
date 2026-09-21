# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    # Adds Verifiable to a model: writes a migration for the required columns
    # AND (when the model file exists) injects the concern include plus a
    # placeholder for the natural-identifier attribute. The inject step is
    # idempotent — running the generator twice won't duplicate the include.
    class VerifiableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "verifiable"
      desc "Add Verifiable columns to a model's table, and wire the concern into the model."

      def configure_model
        path = model_path
        unless File.exist?(path)
          say_status :skip, "#{path} not found — add the concern manually:", :yellow
          say_include_snippet
          return
        end

        contents = File.read(path)

        if contents.include?("Vouch::Verifiable")
          say_status :identical, "#{path} already includes Vouch::Verifiable", :blue
          return
        end

        inject_into_class(path, model_metadata.declaration_name(contents)) do
          <<~RUBY
            include Vouch::Verifiable

            # Natural identifier used to key draft (unpersisted) records —
            # e.g. :address for Email, :e164 for Phone, :label for Totp.
            # self.verifiable_subject_attribute = :your_attr

          RUBY
        end
      end

      private

      def model_path
        File.join(destination_root, model_metadata.model_path)
      end

      def model_class_name
        model_metadata.class_name
      end

      def singular_scope
        model_metadata.class_name.underscore
      end

      def say_include_snippet
        say <<~SNIPPET

          Add to app/models/#{singular_scope}.rb:

            include Vouch::Verifiable

            # Natural identifier used to key draft (unpersisted) records.
            # self.verifiable_subject_attribute = :your_attr

        SNIPPET
      end
    end
  end
end
