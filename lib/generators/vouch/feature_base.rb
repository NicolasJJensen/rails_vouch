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
        migration_template "#{template_name}.rb.tt",
                           "db/migrate/add_#{template_name}_to_#{table_name}.rb"
      end

      private

      def route_declaration_for(model_name, selected_scope = nil)
        path = File.join(destination_root, "config/routes.rb")
        return unless File.file?(path)
        declarations = File.read(path).lines.select { |line| line.match?(/\.scope\b/) }
        matches = if selected_scope
          declarations.select { |line| line.match?(/\.scope\s+:#{Regexp.escape(selected_scope.to_s)}\b/) }
        else
          declarations.select { |line| line.match?(/\b(?:model|identity|account):\s*["']#{Regexp.escape(model_name)}["']/) }
        end
        raise Thor::Error, "Several authentication scopes use #{model_name}; pass --auth-scope" if matches.length > 1
        matches.first
      end

      def inferred_auth_scope(model_name)
        declaration = route_declaration_for(model_name)
        declaration&.match(/\.scope\s+:([a-zA-Z_][a-zA-Z0-9_]*)/)&.captures&.first || model_name.underscore.tr("/", "_")
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

      class << self
        attr_accessor :feature_template_name
      end
    end
  end
end
