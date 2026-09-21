# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    # Adds invitation columns to the identity table and writes a host-app
    # controller that supplies the required `build_invited_identity` hook.
    #
    #   bin/rails g vouch:invitations users Account
    #   bin/rails g vouch:invitations members --single-model
    #
    class InvitationsGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "invitations"
      desc "Add invitation columns to the identity table and write a host controller override."

      # `scope` is inherited from FeatureBase
      argument :account_class, type: :string, optional: true,
                                banner: "AccountClass (required for split-model)"

      class_option :single_model, type: :boolean, default: false,
                                   desc: "Use the scoped model as both account and identity"
      class_option :auth_scope, type: :string, default: nil,
                                desc: "Vouch route scope for the generated controller"
      class_option :controller_path, type: :string, default: nil,
                                     desc: "Controller namespace path used by the authentication routes"

      def validate_account_class!
        return if options[:single_model]
        return if account_class.present?

        raise Thor::Error,
              "Pass the account class as the second argument " \
              "(e.g. `bin/rails g vouch:invitations users Account`), " \
              "or use --single-model if the scope has no separate account class."
      end

      def create_registration_migration
        name = "add_registration_required_to_#{registration_table_name}"
        return if Dir.glob(File.join(destination_root, "db/migrate/*_#{name}.rb")).any?

        migration_template "registration.rb.tt", "db/migrate/#{name}.rb"
      end

      def create_invitations_controller
        template "invitations_controller.rb.tt",
                 "app/controllers/#{controller_scope_path}/invitations_controller.rb"
      end

      def create_invitations_view
        template "invitations_new.html.erb.tt",
                 "app/views/#{view_scope_path}/invitations/new.html.erb"
      end

      private

      def registration_table_name
        options[:single_model] ? table_name : Vouch::ModelMetadata.new(account_class).table_name
      end

      def migration_class_name
        "AddInvitationsTo#{table_name.camelize}"
      end

      def scope_module
        controller_scope_path.camelize
      end

      def identity_class_name
        model_metadata.class_name
      end

      def invitation_account_class
        options[:single_model] ? identity_class_name : account_class
      end

      def controller_scope_path
        options[:controller_path].presence ||
          [model_metadata.class_name.deconstantize,
           model_metadata.class_name.demodulize.pluralize].compact_blank.join("::").underscore
      end

      def view_scope_path
        controller_scope_path.camelize.underscore
      end

      def auth_scope_name
        options[:auth_scope].presence || model_metadata.class_name.demodulize.underscore.singularize
      end
    end
  end
end
