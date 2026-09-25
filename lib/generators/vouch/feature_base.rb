# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"
require "vouch/model_metadata"

module Vouch
  module Generators
    # Shared base for feature generators. Each subclass sets a template name
    # and migration filename. Optional `scope` positional arg picks the table
    # to extend; defaults to "users".
    class FeatureBase < Rails::Generators::Base
      include Rails::Generators::Migration

      argument :scope, type: :string, default: "users", banner: "scope"
      class_option :primary_key_type, type: :string, default: nil,
                                       desc: "Primary key type for generated references (for example, uuid)"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_feature_migration
        template_name = self.class.feature_template_name
        if feature_schema_already_declared?(template_name) || existing_feature_schema_complete?(template_name)
          say_status :identical, "#{template_name} schema already exists", :blue
          return
        end
        validate_existing_feature_schema!(template_name)
        migration_template "#{template_name}.rb.tt",
                           "db/migrate/add_#{template_name}_to_#{table_name}.rb"
      end

      private

      def route_declaration_for(model_name, selected_scope = nil)
        path = File.join(destination_root, "config/routes.rb")
        return unless File.file?(path)
        declarations = File.read(path).lines.select { |line| line.match?(/\.(?:scope|membership)\b/) }
        matches = if selected_scope
          declarations.select { |line| line.match?(/\.(?:scope|membership)\s+:#{Regexp.escape(selected_scope.to_s)}\b/) }
        else
          declarations.select { |line| line.match?(/\b(?:model|identity|account):\s*["']#{Regexp.escape(model_name)}["']/) }
        end
        raise Thor::Error, "Several authentication scopes use #{model_name}; pass --auth-scope" if matches.length > 1
        matches.first
      end

      def inferred_auth_scope(model_name)
        declaration = route_declaration_for(model_name)
        declaration&.match(/\.(?:scope|membership)\s+:([a-zA-Z_][a-zA-Z0-9_]*)/)&.captures&.first || model_name.underscore.tr("/", "_")
      end

      def inferred_controller_path(model_name, scope_name)
        declaration = route_declaration_for(model_name, scope_name) || route_declaration_for(model_name)
        declaration&.match(/\bpath:\s*["']([^"']+)["']/)&.captures&.first || scope_name.to_s.pluralize
      end

      def route_helper_prefix
        declaration = route_declaration_for(model_metadata.class_name, auth_scope_name)
        declaration&.match(/\bas:\s*(?:["']([^"']+)["']|:([a-zA-Z_][a-zA-Z0-9_]*))/)&.captures&.compact&.first || auth_scope_name
      end

      def inject_model_code(path, metadata, wiring)
        source = File.read(path)
        dependency = source.scan(/^[ \t]*include Vouch::(?:Authenticatable|Verifiable|TwoFactorable)[ \t]*\n/).last
        if dependency
          inject_into_file(path, after: dependency) { wiring }
        else
          inject_into_class(path, metadata.declaration_name(source)) { wiring }
        end
      end

      def primary_key_type
        options[:primary_key_type].presence
      end

      def table_name
        model_metadata.table_name
      end

      def model_metadata
        @model_metadata ||= Vouch::ModelMetadata.new(scope)
      end

      def migration_class_name
        "Add#{self.class.feature_template_name.camelize}To#{table_name.camelize}"
      end

      # Do not create a second migration merely because a host used a
      # different filename.  Match the feature's actual columns, rather than
      # guessing from a migration class name.
      def feature_schema_already_declared?(template_name)
        expected = feature_column_types(template_name)
        return false if expected.empty?

        declared = pending_feature_column_types
        return false unless expected.keys.all? { |name| declared.key?(name) }

        incompatible = expected.filter_map do |name, type|
          name unless migration_column_type_matches?(declared[name], type)
        end
        raise Thor::Error, "Pending migrations for #{table_name} are incompatible with #{template_name}; wrong types for #{incompatible.join(', ')}" if incompatible.any?

        true
      end

      def validate_existing_feature_schema!(template_name)
        return unless generating_current_host?
        return unless ActiveRecord::Base.connection.data_source_exists?(table_name)

        expected = feature_column_types(template_name)
        actual = ActiveRecord::Base.connection.columns(table_name).index_by(&:name)
        missing = expected.keys - actual.keys
        return if missing.empty? || missing.length == expected.length

        # An existing table is a host contract.  A partial feature table is
        # unsafe to paper over with a second migration; make the missing
        # columns explicit so the host can reconcile its schema deliberately.
        raise Thor::Error, "Existing #{table_name} is incompatible with #{template_name}; missing #{missing.join(', ')}"
      rescue ActiveRecord::ConnectionNotEstablished
        nil
      end

      def existing_feature_schema_complete?(template_name)
        return false unless generating_current_host? && ActiveRecord::Base.connection.data_source_exists?(table_name)
        expected = feature_column_types(template_name)
        actual = ActiveRecord::Base.connection.columns(table_name).index_by(&:name)
        return false unless expected.keys.all? { |name| actual.key?(name) }

        incompatible = expected.filter_map do |name, type|
          name unless database_column_type_matches?(actual.fetch(name), type)
        end
        raise Thor::Error, "Existing #{table_name} is incompatible with #{template_name}; wrong types for #{incompatible.join(', ')}" if incompatible.any?

        true
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end

      def generating_current_host?
        Rails.respond_to?(:root) && Rails.root.present? &&
          File.expand_path(destination_root) == File.expand_path(Rails.root)
      end

      def feature_columns(template_name)
        feature_column_types(template_name).keys
      end

      def feature_column_types(template_name)
        path = File.join(self.class.source_root, "#{template_name}.rb.tt")
        return {} unless File.file?(path)

        source = File.read(path)
        source.scan(/add_column\s+:<%=\s*table_name\s*%>,\s+:([a-z_]+),\s+:([a-z_]+)/).to_h.merge(
          source.scan(/t\.([a-z_]+)\s+:([a-z_]+)/).map { |type, name| [name, type] }.to_h
        )
      end

      def pending_feature_column_types
        Dir[File.join(destination_root, "db/migrate/*.rb")].each_with_object({}) do |path, columns|
          source = File.read(path)
          source.scan(/add_column\s+:#{Regexp.escape(table_name)},\s+:([a-z_]+),\s+:([a-z_]+)/).each do |name, type|
            columns[name] = type
          end
          table_migration_blocks(source).each do |block|
            block.scan(/t\.([a-z_]+)\s+:([a-z_]+)/).each do |type, name|
              columns[name] = type
            end
          end
        end
      end

      def table_migration_blocks(source)
        table = Regexp.escape(table_name)
        source.scan(/(?:create_table|change_table)\s*\(?\s*:#{table}\b.*?\bdo\b.*?^\s*end/m)
      end

      def migration_column_type_matches?(actual, expected)
        actual.to_s == expected.to_s || (expected.to_s == "bigint" && actual.to_s == "integer")
      end

      def database_column_type_matches?(column, expected)
        expected = expected.to_s
        return true if expected == "bigint" && (column.sql_type.to_s.match?(/bigint/i) || column.type == :integer)

        case expected
        when "string" then column.type == :string
        when "datetime" then %i[datetime timestamp].include?(column.type)
        else column.type.to_s == expected
        end
      end

      class << self
        attr_accessor :feature_template_name
      end
    end
  end
end
