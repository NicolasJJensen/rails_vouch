# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"
require "vouch/model_metadata"

module Vouch
  module Generators
    # Creates the polymorphic vouch_recovery_codes table AND adds
    # recovery_attempts / recovery_locked_at counters to the host table.
    # Both migrations land in the same `bin/rails g vouch:recoverable`
    # invocation so hosts get a single consistent install step.
    class RecoverableGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      argument :scope, type: :string, default: "users", banner: "scope"
      class_option :primary_key_type, type: :string, default: nil,
                                       desc: "Primary key type for the recoverable model (for example, uuid)"

      source_root File.expand_path("templates", __dir__)
      desc "Add Recoverable columns to the host table and create the recovery codes table."

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_host_columns_migration
        migration_template "recoverable.rb.tt",
                           "db/migrate/add_recoverable_to_#{table_name}.rb"
      end

      def create_recovery_codes_migration
        migration_template "recovery_codes.rb.tt",
                           "db/migrate/create_vouch_recovery_codes.rb"
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

      def host_migration_class_name
        "AddRecoverableTo#{table_name.camelize}"
      end

      def codes_migration_class_name
        "CreateVouchRecoveryCodes"
      end
    end
  end
end
