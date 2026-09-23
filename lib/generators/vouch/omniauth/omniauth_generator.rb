# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../route_editor"

module Vouch
  module Generators
    class OmniauthGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "omniauth"
      # A concrete owner preserves the ordinary host's foreign key; polymorphism is an advanced opt-in.
      argument :scope, type: :string, default: "users", banner: "owner_scope",
                       desc: "Credential-owning model, e.g. 'accounts' or 'members'"
      desc "Create the OAuth identity model and wire it to its credential-owning model."

      class_option :auth_scope, type: :string, default: nil
      class_option :controller_path, type: :string, default: nil
      class_option :provider, type: :string, default: nil
      class_option :model_only, type: :boolean, default: false

      def primary_key_type
        options[:primary_key_type].presence
      end

      def create_feature_migration
        migration_template "oauth_identities.rb.tt",
                           "db/migrate/create_oauth_identities.rb"
      end

      def create_model
        path = File.join(destination_root, "app/models/oauth_identity.rb")
        template "oauth_identity.rb.tt", path unless File.file?(path)
      end

      def configure_owner_model
        path = owner_model_path
        unless File.exist?(path)
          say_status :skip, "#{path} not found — add the owner association manually:", :yellow
          say_owner_association
          return
        end

        contents = File.read(path)
        unless contents.include?("authenticates_with :omniauthable")
          inject_into_class(path, owner_metadata.declaration_name(contents)) do
            "\n  include Vouch::Authenticatable\n  authenticates_with :omniauthable\n\n"
          end
          contents = File.read(path)
        end
        if contents.match?(/^\s*has_many\s*(?:\(\s*)?(?::oauth_identities\b|[\"']oauth_identities[\"'])/)
          say_status :identical, "#{path} already has oauth_identities", :blue
          return
        end

        inject_into_class(path, owner_metadata.declaration_name(contents)) do
          <<~RUBY
            has_many :oauth_identities, class_name: "OauthIdentity",
                                      #{owner_metadata.association_options}, dependent: :destroy

          RUBY
        end
      end

      def create_oauth_controller
        return if options[:model_only]
        return unless auth_scope_name
        path = File.join(destination_root, "app/controllers/#{controller_scope_path}/omni_auths_controller.rb")
        template "oauth_callbacks_controller.rb.tt", path unless File.file?(path)
      end

      def configure_routes
        return if options[:model_only]
        return unless auth_scope_name
        path = File.join(destination_root, "config/routes.rb")
        return unless File.file?(path)
        RouteEditor.ensure_wrapper(path, "Vouch.routes(self) do |auth|\nend\n")
        result = RouteEditor.insert_feature(path, auth_scope_name, oauth_route_declaration)
        if result == :unsafe
          block = "auth.scope :#{auth_scope_name}, model: \"#{owner_class}\" do\n  #{oauth_route_declaration}\nend\n"
          result = RouteEditor.insert_scope(path, block)
        end
        say "Add auth.oauth_callbacks inside auth.scope :#{auth_scope_name} in config/routes.rb", :yellow if result == :unsafe
      end

      def create_provider_initializer
        return if options[:model_only] || options[:provider].blank?
        unless options[:provider].match?(/\A[a-z][a-z0-9_]*\z/)
          raise Thor::Error, "Provider must be a strategy name such as github"
        end
        path = File.join(destination_root, "config/initializers/vouch_omniauth_#{options[:provider]}.rb")
        template "provider_initializer.rb.tt", path unless File.file?(path)
        say "Add omniauth, omniauth-#{options[:provider].tr("_", "-")}, and omniauth-rails_csrf_protection, then configure the provider credentials.", :yellow
      end

      private

      def oauth_route_declaration
        "auth.oauth_callbacks controller: \"#{controller_scope_path}/omni_auths\""
      end

      def owner_metadata
        @owner_metadata ||= Vouch::ModelMetadata.new(scope)
      end

      def owner_class
        owner_metadata.class_name
      end

      def owner_table
        owner_metadata.table_name
      end

      def owner_association
        owner_metadata.association_key
      end

      def owner_primary_keys
        owner_metadata.primary_keys
      end

      def owner_primary_key_types
        owner_metadata.primary_key_types
      end

      def owner_model_path
        File.join(destination_root, owner_metadata.model_path)
      end

      def owner_class_option
        return "" if owner_class == owner_association.camelize

        ", class_name: \"#{owner_class}\""
      end

      def say_owner_association
        say <<~RUBY

          Add to #{owner_metadata.model_path}:

            has_many :oauth_identities, class_name: "OauthIdentity",
                                      #{owner_metadata.association_options}, dependent: :destroy

        RUBY
      end

      def migration_class_name
        "CreateOauthIdentities"
      end

      def auth_scope_name
        options[:auth_scope].presence || inferred_auth_scope(owner_class)
      end

      def controller_scope_path
        options[:controller_path].presence || inferred_controller_path(owner_class, auth_scope_name)
      end
    end
  end
end
