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
