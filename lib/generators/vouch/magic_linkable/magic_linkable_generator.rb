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

      def configure_model
        path = model_path
        unless File.exist?(path)
          say_status :skip, "#{path} not found — add the concern manually:", :yellow
          say_include_snippet
          return
        end

        contents = File.read(path)

        if contents.include?("Vouch::MagicLinkable")
          say_status :identical, "#{path} already includes Vouch::MagicLinkable", :blue
          return
        end

        inject_into_class(path, model_metadata.declaration_name(contents)) do
          <<~RUBY
            include Vouch::MagicLinkable

            # Deliver a one-time sign-in code over this credential's channel.
            # For SMS: SmsCourier.send(e164, "Your sign-in code: \#{code}").
            # For email: SignInMailer.code(self, code).deliver_later.
            #
            # def deliver_sign_in_code(code)
            # end

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

            include Vouch::MagicLinkable

            def deliver_sign_in_code(code)
              # SmsCourier.send(e164, "Your sign-in code: \#{code}")
            end

        SNIPPET
      end
    end
  end
end
