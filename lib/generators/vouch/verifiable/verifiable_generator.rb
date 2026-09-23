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

      class_option :subject, type: :array, default: []

      def configure_model
        path = model_path
        unless File.exist?(path)
          say_status :skip, "#{path} not found — add the concern manually:", :yellow
          say_include_snippet
          return
        end

        contents = File.read(path)

        wiring = +"\n"
        wiring << "  include Vouch::Verifiable\n" unless contents.include?("include Vouch::Verifiable")
        if options[:subject].any? && !contents.include?("verifiable_subject_attribute")
          attributes = options[:subject].map do |name|
            raise Thor::Error, "Invalid subject attribute" unless name.match?(/\A[a-z_][a-z0-9_]*\z/)
            name.to_sym
          end
          value = attributes.one? ? attributes.first.inspect : attributes.inspect
          wiring << "  self.verifiable_subject_attribute = #{value}\n"
        end
        unless contents.include?("def deliver_verification_code")
          wiring << "\n  def deliver_verification_code(_code)\n    raise NotImplementedError, \"Implement verification delivery\"\n  end\n"
        end
        inject_model_code(path, model_metadata, wiring) unless wiring == "\n"
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
