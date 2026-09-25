# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"
require "vouch/model_metadata"

module Vouch
  module Generators
    # Creates the backup-codes join table and model for a 2FA credential
    # class, and wires BackupCodable into the parent model.
    #
    #   bin/rails g vouch:backup_codes totps
    #
    # Produces:
    #   - db/migrate/create_totp_backup_codes.rb
    #   - app/models/totp_backup_code.rb
    #   - injects `include Vouch::BackupCodable` and
    #     `has_many :backup_codes, class_name: "TotpBackupCode",
    #      dependent: :destroy` into app/models/totp.rb
    class BackupCodesGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :scope, type: :string, banner: "parent_scope",
                       desc: "Parent scope, e.g. 'totps' (the model that owns the backup codes)"
      class_option :primary_key_type, type: :string, default: nil,
                                       desc: "Primary key type for generated tables and references (for example, uuid)"

      desc "Create backup-codes table + model and wire BackupCodable into the parent."

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_backup_codes_migration
        return existing_backup_table! if schema_table_exists?(join_table_name) || pending_table_migration?(join_table_name)
        migration_template "backup_codes.rb.tt",
                           "db/migrate/create_#{join_table_name}.rb"
      end

      def create_model
        template "backup_code_model.rb.tt",
                 "app/models/#{backup_code_class.underscore}.rb"
      end

      def configure_parent_model
        path = parent_path
        unless File.exist?(path)
          say_status :skip, "#{path} not found — wire the parent manually:", :yellow
          say_wire_snippet
          return
        end

        contents = File.read(path)
        wiring = []

        wiring << "include Vouch::BackupCodable" unless contents.include?("Vouch::BackupCodable")
        unless contents.match?(/^\s*has_many\s*(?:\(\s*)?(?::backup_codes\b|["']backup_codes["'])/)
          wiring << <<~RUBY
            has_many :backup_codes, class_name: "#{backup_code_class}",
                                    #{parent_metadata.association_options(parent_singular)}, dependent: :destroy
          RUBY
        end

        if wiring.empty?
          say_status :identical, "#{path} already wires BackupCodable and backup_codes", :blue
          return
        end

        inject_into_class(path, parent_metadata.declaration_name(contents)) do
          "\n#{wiring.join("\n\n")}\n\n"
        end
      end

      private

      def existing_backup_table!
        validate_existing_table!(join_table_name, %w[code_digest])
        say_status :identical, "#{join_table_name} already exists", :blue
      end

      def schema_table_exists?(table)
        return false unless generating_current_host?
        ActiveRecord::Base.connection.data_source_exists?(table)
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end

      def pending_table_migration?(table)
        Dir[File.join(destination_root, "db/migrate/*.rb")].any? { |path| File.read(path).match?(/create_table\s*(?:\(\s*)?:#{Regexp.escape(table)}\b/) }
      end

      def generating_current_host?
        Rails.respond_to?(:root) && Rails.root.present? &&
          File.expand_path(destination_root) == File.expand_path(Rails.root)
      end

      def validate_existing_table!(table, columns)
        return unless schema_table_exists?(table)
        missing = columns - ActiveRecord::Base.connection.columns(table).map(&:name)
        raise Thor::Error, "Existing #{table} is incompatible; missing #{missing.join(', ')}" if missing.any?
      end

      def primary_key_type
        options[:primary_key_type].presence
      end

      def migration_class_name
        "Create#{join_table_name.camelize}"
      end

      # e.g. scope="totps" -> "totp_backup_codes"
      def join_table_name
        "#{parent_metadata.table_name.singularize}_backup_codes"
      end

      # e.g. scope="totps" -> "totp"
      def parent_singular
        parent_metadata.param_key
      end

      # e.g. "Totp"
      def parent_class
        parent_metadata.class_name
      end

      # e.g. "TotpBackupCode"
      def backup_code_class
        "#{parent_class}BackupCode"
      end

      def parent_path
        File.join(destination_root, parent_metadata.model_path)
      end

      def parent_metadata
        @parent_metadata ||= Vouch::ModelMetadata.new(scope)
      end

      def say_wire_snippet
        say <<~SNIPPET

          Add to app/models/#{parent_singular}.rb:

            include Vouch::BackupCodable
            has_many :backup_codes, class_name: "#{backup_code_class}",
                                    #{parent_metadata.association_options(parent_singular)}, dependent: :destroy

        SNIPPET
      end
    end
  end
end
