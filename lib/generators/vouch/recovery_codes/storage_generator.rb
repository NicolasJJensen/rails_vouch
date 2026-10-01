# frozen_string_literal: true

require_relative "../backup_codes/backup_codes_generator"
require_relative "../schema_repair"

module Vouch
  module Generators
    class RecoveryCodeStorageGenerator < BackupCodesGenerator
      include SchemaRepair
      source_root File.expand_path("templates", __dir__)
      class_option :polymorphic, type: :boolean, default: false
      class_option :credential, type: :boolean, default: false

      no_tasks do
        def validate_configuration!
          return if custom_association?
          validate_model!
          if options[:polymorphic] && parent_metadata.composite_primary_key?
            raise Thor::Error, "Composite recovery owners need concrete storage; omit --polymorphic"
          end
          validate_storage! if schema_table_exists?(join_table_name) || pending_table_migration?(join_table_name)
        end
      end

      def create_backup_codes_migration
        validate_configuration!
        return if custom_association?
        if schema_table_exists?(join_table_name) || pending_table_migration?(join_table_name)
          foreign = options[:polymorphic] ? [] : [{ to_table: parent_metadata.table_name, column: storage_keys, primary_key: parent_metadata.primary_keys }]
          repair_schema_constraints(join_table_name, required: storage_keys + %w[code_digest], indexes: [storage_keys, "used_at"], foreign_keys: foreign)
          say_status :identical, "#{join_table_name} already exists", :blue
          return
        end
        migration_template "storage.rb.tt", "db/migrate/create_#{join_table_name}.rb"
      end

      def create_model
        return if custom_association?
        path = "app/models/#{backup_code_class.underscore}.rb"
        template "model.rb.tt", path unless File.exist?(File.join(destination_root, path))
      end

      def configure_parent_model
        return if custom_association?
        return unless File.file?(parent_path)
        source = File.read(parent_path)
        concern = options[:credential] ? "BackupCodable" : "Recoverable"
        wiring = []
        wiring << "include Vouch::#{concern}" unless source.include?("Vouch::#{concern}")
        unless source.match?(/^\s*has_many\s*(?:\(\s*)?:recovery_codes\b/)
          association = options[:polymorphic] ? "as: :recoverable" : parent_metadata.association_options(parent_singular)
          wiring << "has_many :recovery_codes, class_name: \"#{backup_code_class}\", #{association}, dependent: :destroy"
        end
        wiring << "recovery_codes_from :recovery_codes" unless source.match?(/\brecovery_codes_from\b/)
        return if wiring.empty?
        code = "\n  #{wiring.join("\n  ")}\n"
        dependency = source[/^\s*include Vouch::#{concern}\s*$/]
        if dependency
          inject_into_file(parent_path, after: dependency) { code }
        else
          inject_into_class(parent_path, parent_metadata.declaration_name(source)) { code }
        end
      end

      private

      def custom_association?
        return false unless File.file?(parent_path)
        source = File.read(parent_path)
        declaration = source[/^\s*recovery_codes_from\s*(?:\(\s*)?(?::([a-z_]+)|["']([a-z_]+)["'])/, 1] ||
          source[/^\s*recovery_codes_from\s*(?:\(\s*)?["']([a-z_]+)["']/, 1]
        if source.match?(/^\s*recovery_codes_from\b/) && !declaration
          raise Thor::Error, "Use a literal association name in recovery_codes_from before running the generator"
        end
        return false unless declaration
        return true unless declaration == "recovery_codes"
        association = source[/has_many\s*(?:\(\s*)?:recovery_codes\b([^\n]*)/, 1]
        custom_class = association&.match(/class_name:\s*["']([^"']+)["']/)&.captures&.first
        custom_class.present? && custom_class != backup_code_class
      end

      def join_table_name
        options[:polymorphic] ? "recovery_codes" : "#{parent_metadata.table_name.singularize}_recovery_codes"
      end

      def backup_code_class
        options[:polymorphic] ? "RecoveryCode" : "#{parent_class}RecoveryCode"
      end

      def storage_keys
        options[:polymorphic] ? %w[recoverable_type recoverable_id] : parent_metadata.foreign_keys(parent_singular)
      end

      def validate_model!
        path = File.join(destination_root, "app/models/#{backup_code_class.underscore}.rb")
        return unless File.file?(path)
        source = File.read(path)
        owner_name = options[:polymorphic] ? "recoverable" : parent_singular
        declaration = source[/belongs_to\s*(?:\(\s*)?:#{Regexp.escape(owner_name)}\b([^\n]*)/, 1]
        declared_class = declaration&.match(/class_name:\s*["']([^"']+)["']/)&.captures&.first
        if !options[:polymorphic] && declared_class && declared_class != parent_class
          raise Thor::Error, "#{backup_code_class}'s #{owner_name} association must target #{parent_class}"
        end
        unless declaration && (!options[:polymorphic] || declaration.include?("polymorphic: true"))
          raise Thor::Error, "#{backup_code_class} must belong_to :#{owner_name} for the selected recovery storage"
        end
      end

      def validate_storage!
        required = storage_keys + %w[code_digest used_at]
        if schema_table_exists?(join_table_name)
          validate_existing_table!(join_table_name, required)
          columns = ActiveRecord::Base.connection.columns(join_table_name).index_by(&:name)
          expected = { "code_digest" => :string, "used_at" => :datetime }
          if options[:polymorphic]
            expected.merge!("recoverable_type" => :string, "recoverable_id" => (primary_key_type || parent_metadata.primary_key_types.values.first).to_sym)
          else
            parent_metadata.primary_keys.zip(storage_keys).each do |key, foreign|
              expected[foreign] = (primary_key_type || parent_metadata.primary_key_types[key]).to_sym
            end
          end
          expected.each do |name, type|
            actual = columns.fetch(name)
            actual_type = actual.sql_type == "bigint" ? :bigint : actual.type
            raise Thor::Error, "#{join_table_name}.#{name} must use #{type}" unless actual_type == type
          end
          unless options[:polymorphic]
            ActiveRecord::Base.connection.foreign_keys(join_table_name).each do |foreign|
              next if (Array(foreign.column).map(&:to_s) & storage_keys).empty?
              unless foreign.to_table == parent_metadata.table_name && Array(foreign.column).map(&:to_s) == storage_keys && Array(foreign.primary_key).map(&:to_s) == parent_metadata.primary_keys
                raise Thor::Error, "#{join_table_name} has incompatible recovery ownership"
              end
            end
          end
          return
        end
        sources = Dir[File.join(destination_root, "db/migrate/*.rb")].map { |path| File.read(path) }
        source = sources.find { |body| body.match?(/create_table\s*(?:\(\s*)?:#{Regexp.escape(join_table_name)}\b/) }
        columns = source.scan(/t\.(?:string|datetime|bigint|integer|uuid)\s+:([a-z_]+)/).flatten
        source.scan(/t\.references\s+:([a-z_]+)([^\n]*)/).each do |name, options|
          columns << "#{name}_id"
          columns << "#{name}_type" if options.include?("polymorphic: true")
        end
        if options[:polymorphic]
          reference = source[/t\.references\s+:recoverable\b([^\n]*)/, 1]
          actual_type = if reference
            reference[/\btype:\s*:([a-z_]+)/, 1] || (reference.include?("type:") ? nil : "bigint")
          else
            source[/t\.(bigint|integer|string|uuid)\s+:recoverable_id\b/, 1]
          end
          expected_type = (primary_key_type || parent_metadata.primary_key_types.values.first).to_s
          unless actual_type == expected_type
            raise Thor::Error, "Pending #{join_table_name}.recoverable_id uses #{actual_type || 'an unknown type'}; #{parent_class} needs #{expected_type}. Use concrete recovery storage for incompatible owner key types"
          end
        end
        unless options[:polymorphic]
          targets = source.scan(/(?:to_table:\s*:|(?:add_)?foreign_key\s+[^\n]*?:)([a-z_][a-z0-9_]*)/).flatten
          if targets.any? { |target| target != parent_metadata.table_name }
            raise Thor::Error, "Pending #{join_table_name} has incompatible recovery ownership"
          end
        end
        missing = required - columns
        raise Thor::Error, "Existing #{join_table_name} migration is incompatible; missing #{missing.join(', ')}" if missing.any?
      end
    end
  end
end
