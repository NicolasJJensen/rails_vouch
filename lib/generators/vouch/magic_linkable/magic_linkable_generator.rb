# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    # Adds MagicLinkable to a model: writes a migration for the sign-in
    # attempt counter and lockout timestamp, then injects the concern
    # include plus a deliver_sign_in_code override placeholder into the
    # target model. Idempotent — running twice won't duplicate the include.
    class MagicLinkableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "magic_linkable"
      desc "Add MagicLinkable columns to a model's table and wire the concern into the model."

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
        wiring << "  include Vouch::MagicLinkable\n" unless contents.include?("include Vouch::MagicLinkable")
        if options[:subject].any? && !contents.include?("verifiable_subject_attribute")
          attributes = options[:subject].map do |name|
            raise Thor::Error, "Invalid subject attribute" unless name.match?(/\A[a-z_][a-z0-9_]*\z/)
            name.to_sym
          end
          value = attributes.one? ? attributes.first.inspect : attributes.inspect
          wiring << "  self.verifiable_subject_attribute = #{value}\n"
        end
        unless contents.include?("def deliver_sign_in_code")
          wiring << "\n  def deliver_sign_in_code(_code)\n    raise NotImplementedError, \"Implement sign-in code delivery\"\n  end\n"
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

            include Vouch::MagicLinkable

            def deliver_sign_in_code(code)
              # SmsCourier.send(e164, "Your sign-in code: \#{code}")
            end

        SNIPPET
      end
    end
  end
end
