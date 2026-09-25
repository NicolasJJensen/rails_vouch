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
        return pending_host_schema! if host_schema_declared?
        return existing_host_schema! if host_schema_complete?
        validate_partial_host_schema!
        migration_template "recoverable.rb.tt",
                           "db/migrate/add_recoverable_to_#{table_name}.rb"
      end

      def create_recovery_codes_migration
        return existing_codes_schema! if codes_schema_complete?
        return pending_codes_schema! if codes_schema_declared?
        migration_template "recovery_codes.rb.tt",
                           "db/migrate/create_vouch_recovery_codes.rb"
      end

      def configure_model
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)
        source = File.read(path)
        return if source.include?("include Vouch::Recoverable") || source.include?("authenticates_with :recoverable")
        inject_into_class(path, model_metadata.declaration_name(source)) { "\n  include Vouch::Recoverable\n" }
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

      def recoverable_primary_keys
        model_metadata.primary_keys
      end

      def recoverable_primary_key_type
        (primary_key_type || model_metadata.primary_key_types[recoverable_primary_keys.first] || :bigint).to_sym
      end

      def composite_recoverable?
        recoverable_primary_keys.length > 1
      end

      def host_migration_class_name
        "AddRecoverableTo#{table_name.camelize}"
      end

      def codes_migration_class_name
        "CreateVouchRecoveryCodes"
      end

      def host_schema_declared?
        columns = pending_table_columns(table_name)
        required = %w[recovery_attempts recovery_locked_at]
        return false if (required & columns).empty?

        missing = required - columns
        raise Thor::Error, "Pending migrations for #{table_name} are incompatible with recoverable; missing #{missing.join(', ')}" if missing.any?

        true
      end

      def pending_host_schema!
        say_status :identical, "recoverable schema already exists", :blue
      end

      def codes_schema_declared?
        columns = pending_table_columns("vouch_recovery_codes")
        return false if columns.empty?

        required = recovery_code_columns
        missing = required - columns
        raise Thor::Error, "Pending vouch_recovery_codes migration is incompatible; missing #{missing.join(', ')}" if missing.any?

        true
      end

      def pending_codes_schema!
        say_status :identical, "vouch_recovery_codes schema already exists", :blue
      end

      def pending_table_columns(table)
        escaped = Regexp.escape(table)
        Dir[File.join(destination_root, "db/migrate/*.rb")].flat_map do |path|
          source = File.read(path)
          blocks = source.scan(/(?:create_table|change_table)\s*\(?\s*:#{escaped}\b.*?\bdo\b.*?^\s*end/m)
          blocks.flat_map { |block| block.scan(/t\.\w+\s+:([a-z_]+)/).flatten } +
            source.scan(/add_column\s+:#{escaped},\s+:([a-z_]+)/).flatten
        end.uniq
      end

      def generating_current_host?
        Rails.respond_to?(:root) && Rails.root.present? &&
          File.expand_path(destination_root) == File.expand_path(Rails.root)
      end

      def host_schema_complete?
        return false unless generating_current_host? && ActiveRecord::Base.connection.data_source_exists?(table_name)

        %w[recovery_attempts recovery_locked_at].all? { |column| ActiveRecord::Base.connection.column_exists?(table_name, column) }
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end

      def validate_partial_host_schema!
        return unless generating_current_host? && ActiveRecord::Base.connection.data_source_exists?(table_name)

        required = %w[recovery_attempts recovery_locked_at]
        present = ActiveRecord::Base.connection.columns(table_name).map(&:name)
        missing = required - present
        return if missing.length == required || missing.empty?

        raise Thor::Error, "Existing #{table_name} is incompatible with recoverable; missing #{missing.join(', ')}"
      rescue ActiveRecord::ConnectionNotEstablished
        nil
      end

      def existing_host_schema!
        say_status :identical, "recoverable schema already exists", :blue
      end

      def codes_schema_complete?
        return false unless generating_current_host? && ActiveRecord::Base.connection.data_source_exists?("vouch_recovery_codes")

        required = recovery_code_columns
        actual = ActiveRecord::Base.connection.columns("vouch_recovery_codes").map(&:name)
        missing = required - actual
        raise Thor::Error, "Existing vouch_recovery_codes is incompatible; missing #{missing.join(', ')}" if missing.any?

        true
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end

      def existing_codes_schema!
        say_status :identical, "vouch_recovery_codes already exists", :blue
      end

      def recovery_code_columns
        %w[recoverable_type recoverable_id code_digest used_at] + (composite_recoverable? ? ["recoverable_key"] : [])
      end
    end
  end
end
