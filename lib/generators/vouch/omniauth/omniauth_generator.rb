# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class OmniauthGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "omniauth"
      # A concrete owner preserves the ordinary host's foreign key; polymorphism is an advanced opt-in.
      argument :scope, type: :string, default: "accounts", banner: "owner_scope",
                       desc: "Credential-owning model, e.g. 'accounts' or 'members'"
      desc "Create the OAuth identity model and wire it to its credential-owning model."

      def primary_key_type
        options[:primary_key_type].presence
      end

      def create_feature_migration
        migration_template "oauth_identities.rb.tt",
                           "db/migrate/create_oauth_identities.rb"
      end

      def create_model
        template "oauth_identity.rb.tt", "app/models/oauth_identity.rb"
      end

      def configure_owner_model
        path = owner_model_path
        unless File.exist?(path)
          say_status :skip, "#{path} not found — add the owner association manually:", :yellow
          say_owner_association
          return
        end

        contents = File.read(path)
        if contents.match?(/^\s*has_many\s*(?:\(\s*)?(?::oauth_identities\b|[\"']oauth_identities[\"'])/)
          say_status :identical, "#{path} already has oauth_identities", :blue
          return
        end

        inject_into_class(path, owner_metadata.declaration_name(contents)) do
          <<~RUBY
            has_many :oauth_identities, class_name: "OauthIdentity",
                                      foreign_key: :#{owner_association}_id, dependent: :destroy

          RUBY
        end
      end

      private

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
                                      foreign_key: :#{owner_association}_id, dependent: :destroy

        RUBY
      end

      def migration_class_name
        "CreateOauthIdentities"
      end
    end
  end
end
