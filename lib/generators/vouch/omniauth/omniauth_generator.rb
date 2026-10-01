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
        if existing_oauth_schema_complete?
          say_status :identical, "oauth_identities schema already exists", :blue
          return
        end
        if (source = pending_oauth_table_source)
          validate_pending_oauth_columns!(source)
          repair_oauth_constraints unless pending_oauth_constraints_complete?(source)
          say_status :identical, "OAuth identities migration already exists", :blue
          return
        end
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
        @owner_metadata ||= Vouch::ModelMetadata.new(scope, root: destination_root)
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

      def oauth_owner_columns
        association = polymorphic_oauth_association
        association ? ["#{association}_type", "#{association}_id"] : owner_metadata.foreign_keys
      end

      def pending_oauth_table_source
        sources = Dir[File.join(destination_root, "db/migrate/*.rb")].filter_map do |path|
          source = File.read(path)
          raise Thor::Error, "Invalid Ruby migration: #{path}" unless Ripper.sexp(source)
          source = schema_source(source)
          source[/(?:create_table|change_table)\s*(?:\(\s*)?:oauth_identities\b.*?^\s*end/m]
        end
        sources.join("\n").presence
      end

      def validate_pending_oauth_columns!(source)
        columns = source.scan(/t\.([a-z_]+)\s+:([a-z][a-z0-9_]*)/).map { |type, name| [name, type] }.to_h
        source.scan(/t\.(?:references|belongs_to)\s+:([a-z][a-z0-9_]*)([^\n]*)/).each do |association, options|
          columns["#{association}_id"] = options[/type:\s*:([a-z_]+)/, 1] || "bigint"
          columns["#{association}_type"] = "string" if options.match?(/polymorphic:\s*true/)
        end
        missing = (%w[provider uid auth_data] + oauth_owner_columns) - columns.keys
        raise Thor::Error, "Pending oauth_identities migration is incomplete; add #{missing.join(', ')} before generating OAuth" if missing.any?
        invalid = %w[provider uid].reject { |name| columns[name] == "string" }
        invalid << "auth_data" unless %w[json jsonb].include?(columns["auth_data"])
        unless polymorphic_oauth_association
          owner_primary_keys.zip(oauth_owner_columns).each do |key, column|
            expected = primary_key_type || owner_primary_key_types.fetch(key)
            invalid << column unless migration_column_type_matches?(columns[column], expected)
          end
          reference = source[/t\.(?:references|belongs_to)\s+:#{Regexp.escape(owner_association)}\b[^\n]*/]
          target = reference && reference[/to_table:\s*:([a-z][a-z0-9_]*)/, 1]
          primary = reference && literal_key_option(reference, "primary_key")
          if (target && target != owner_table) || (primary && primary != owner_primary_keys)
            raise Thor::Error, "Pending oauth_identities owner foreign key does not reference #{owner_table}(#{owner_primary_keys.join(', ')})"
          end
          source.scan(/t\.foreign_key\s+:([a-z][a-z0-9_]*)(.*?)(?=\n\s*t\.|\n\s*end|\z)/m).each do |table, options|
            references_owner = options.include?("column:") && oauth_owner_columns.any? { |column| options.match?(/[:"']#{Regexp.escape(column)}\b/) }
            primary = literal_key_option(options, "primary_key") || ["id"]
            if references_owner && (table != owner_table || primary != owner_primary_keys)
              raise Thor::Error, "Pending oauth_identities owner foreign key does not reference #{owner_table}(#{owner_primary_keys.join(', ')})"
            end
          end
        end
        raise Thor::Error, "Pending oauth_identities has incompatible column types: #{invalid.join(', ')}" if invalid.any?
      end

      def pending_oauth_constraints_complete?(source)
        required = (%w[provider uid] + oauth_owner_columns).all? do |column|
          source.match?(/t\.\w+\s+:#{Regexp.escape(column)}\b[^\n]*null:\s*false/) ||
            (column.end_with?("_id", "_type") && source.match?(/t\.references\s+:#{Regexp.escape(column.sub(/_(id|type)\z/, ""))}\b[^\n]*null:\s*false/))
        end
        unique = source.match?(/t\.index\s+\[(?:\s*:provider|\s*["']provider["'])\s*,(?:\s*:uid|\s*["']uid["'])\s*\][^\n]*unique:\s*true/)
        foreign = polymorphic_oauth_association || pending_owner_foreign_key?(source)
        required && unique && foreign && pending_owner_index?(source) && !source.match?(/t\.index[^\n]*provider[^\n]*where:/)
      end

      def pending_owner_index?(source)
        if oauth_owner_columns.one?
          column = Regexp.escape(oauth_owner_columns.first)
          return true if source.match?(/t\.\w+\s+:#{column}\b[^\n]*index:\s*(?:true|\{)/)
        end
        association = polymorphic_oauth_association || owner_association
        if polymorphic_oauth_association || owner_primary_keys == ["id"]
          reference = source[/t\.(?:references|belongs_to)\s+:#{Regexp.escape(association)}\b[^\n]*/]
          return true if reference && !reference.match?(/index:\s*false/)
        end
        source.scan(/t\.index\s+([^\n]+)/).any? do |(options)|
          literal_key_option("columns: #{options}", "columns") == oauth_owner_columns && !options.include?("where:")
        end
      end

      def pending_owner_foreign_key?(source)
        reference = source[/t\.(?:references|belongs_to)\s+:#{Regexp.escape(owner_association)}\b[^\n]*/]
        if owner_primary_keys == ["id"] && reference
          return false if reference.include?("primary_key:") && literal_key_option(reference, "primary_key") != owner_primary_keys
          return true if reference.include?("to_table: :#{owner_table}")
          return true if reference.match?(/foreign_key:\s*true/) && owner_association.pluralize == owner_table
        end
        source.scan(/t\.foreign_key\s+:([a-z][a-z0-9_]*)([^\n]*)/).any? do |table, options|
          columns = literal_key_option(options, "column")
          primary = literal_key_option(options, "primary_key") || ["id"]
          table == owner_table && columns == oauth_owner_columns && primary == owner_primary_keys
        end
      end

      def literal_key_option(options, name)
        value = options[/\b#{name}:\s*(\[[^\]]+\]|:[a-z][a-z0-9_]*|["'][a-z][a-z0-9_]*["'])/, 1]
        value&.scan(/[:"']([a-z][a-z0-9_]*)/)&.flatten
      end

      def existing_oauth_schema_complete?
        return false unless generating_current_host? && ActiveRecord::Base.connection.data_source_exists?("oauth_identities")

        connection = ActiveRecord::Base.connection
        columns = connection.columns("oauth_identities").index_by(&:name)
        required = %w[provider uid auth_data] + oauth_owner_columns
        missing = required - columns.keys
        raise Thor::Error, "Existing oauth_identities is incompatible; missing #{missing.join(', ')}" if missing.any?
        invalid = %w[provider uid].reject { |name| columns[name].type == :string }
        invalid << "auth_data" unless %i[json jsonb].include?(columns["auth_data"].type)
        unless polymorphic_oauth_association
          owner_primary_keys.zip(oauth_owner_columns).each do |key, column|
            expected = primary_key_type || owner_primary_key_types.fetch(key)
            invalid << column unless database_column_type_matches?(columns[column], expected)
          end
        end
        raise Thor::Error, "Existing oauth_identities has incompatible column types: #{invalid.join(', ')}" if invalid.any?
        unless polymorphic_oauth_association
          foreigns = connection.foreign_keys("oauth_identities").select { |key| Array(key.column).map(&:to_s) == oauth_owner_columns }
          if foreigns.any? { |key| key.to_table != owner_table || Array(key.primary_key).map(&:to_s) != owner_primary_keys }
            raise Thor::Error, "Existing oauth_identities owner foreign key does not reference #{owner_table}(#{owner_primary_keys.join(', ')})"
          end
        end
        required_nulls = (%w[provider uid] + oauth_owner_columns).all? { |name| !columns[name].null }
        unique = connection.indexes("oauth_identities").any? { |index| index.unique && index.columns == %w[provider uid] && index.where.nil? }
        foreign = polymorphic_oauth_association || connection.foreign_keys("oauth_identities").any? do |key|
          key.to_table == owner_table && Array(key.column).map(&:to_s) == oauth_owner_columns && Array(key.primary_key).map(&:to_s) == owner_primary_keys
        end
        repair_oauth_constraints unless required_nulls && unique && foreign && connection.index_exists?("oauth_identities", oauth_owner_columns)
        true
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end

      def repair_oauth_constraints
        name = "repair_oauth_identity_constraints"
        return if Dir[File.join(destination_root, "db/migrate/*_#{name}.rb")].any?
        @oauth_required_columns = %w[provider uid] + oauth_owner_columns
        @oauth_polymorphic = polymorphic_oauth_association.present?
        migration_template "repair_oauth_identity_constraints.rb.tt", "db/migrate/#{name}.rb"
      end

      def polymorphic_oauth_association
        path = File.join(destination_root, "app/models/oauth_identity.rb")
        return unless File.file?(path)

        File.read(path).scan(/^\s*belongs_to\s*(?:\(\s*)?:([a-z_]+)(.*?)(?=^\s*(?:belongs_to|has_one|has_many|def|class|end)\b|\z)/m).find do |_name, declaration|
          declaration.match?(/\bpolymorphic:\s*true/)
        end&.first
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
