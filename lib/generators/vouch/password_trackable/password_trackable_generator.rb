# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../schema_repair"

module Vouch
  module Generators
    class PasswordTrackableGenerator < FeatureBase
      include SchemaRepair
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "password_trackable"
      desc "Create the password_archives table for password history tracking."

      class_option :polymorphic, type: :boolean, default: false,
                                  desc: "Use a polymorphic archive owner"

      def validate_archive_storage
        if polymorphic? && model_metadata.composite_primary_key?
          raise Thor::Error, "Composite password archive owners need concrete storage; omit --polymorphic"
        end

        owner_path = File.join(destination_root, model_metadata.model_path)
        if File.file?(owner_path)
          association = File.read(owner_path).lines.find { |line| line.match?(/\bhas_many\s+:password_archives\b/) }
          if association
            compatible = polymorphic? ? association.match?(/\bas:\s*:owner\b/) : !association.match?(/\bas:/)
            declared_keys = association[/foreign_key:\s*(\[[^\]]+\]|:[a-z_][a-z0-9_]*|["'][^"']+["'])/, 1]
            if declared_keys
              keys = declared_keys.scan(/[a-z_][a-z0-9_]*/)
              compatible &&= keys == model_metadata.foreign_keys(archive_owner_name)
            end
            raise Thor::Error, "Existing password_archives association is incompatible; preserve or update its ownership explicitly." unless compatible
          end
        end

        path = File.join(destination_root, "app/models/password_archive.rb")
        if File.file?(path)
          source = File.read(path)
          association = source.lines.find { |line| line.match?(/\bbelongs_to\s+:#{Regexp.escape(archive_owner_name)}\b/) }
          compatible = association && source.include?("Vouch::PasswordArchive::Concern")
          compatible &&= polymorphic? ? association.match?(/polymorphic:\s*true/) : !association.include?("polymorphic:")
          if compatible && !polymorphic?
            declared_class = association[/class_name:\s*["']([^"']+)["']/, 1]
            compatible &&= (declared_class || archive_owner_name.classify) == model_metadata.class_name
          end
          raise Thor::Error, "Existing PasswordArchive ownership does not match this command; keep its mapping or migrate it explicitly." unless compatible
        end

        if schema_table_exists?("password_archives")
          validate_existing_table!("password_archives", archive_columns)
          connection = ActiveRecord::Base.connection
          columns = connection.columns("password_archives").index_by(&:name)
          expected = { "password_digest" => :string, "created_at" => :datetime }
          if polymorphic?
            expected.merge!("owner_type" => :string, "owner_id" => (primary_key_type || owner_primary_key_types.values.first).to_sym)
          else
            owner_primary_keys.zip(model_metadata.foreign_keys(archive_owner_name)).each do |key, foreign|
              expected[foreign] = (primary_key_type || owner_primary_key_types[key]).to_sym
            end
          end
          expected.each do |name, type|
            column = columns.fetch(name)
            actual = column.sql_type == "bigint" ? :bigint : column.type
            raise Thor::Error, "password_archives.#{name} must use #{type}" unless actual == type
          end
          unless polymorphic?
            foreign_keys = connection.foreign_keys("password_archives")
            matching = foreign_keys.all? do |foreign_key|
              next true if (Array(foreign_key.column).map(&:to_s) & model_metadata.foreign_keys(archive_owner_name)).empty?
              foreign_key.to_table == model_metadata.table_name &&
                Array(foreign_key.column).map(&:to_s) == model_metadata.foreign_keys(archive_owner_name) &&
                Array(foreign_key.primary_key).map(&:to_s) == owner_primary_keys
            end
            raise Thor::Error, "Existing password_archives foreign key does not match #{model_metadata.table_name}; migrate its ownership explicitly." unless matching
          end
        else
          pending_archive_migrations.each do |migration|
            source = File.read(migration)[/create_table\s*\(?\s*:password_archives\b.*?\bdo\b.*?^\s*end/m].to_s
            expected_reference = source.match?(/\b(?:references|belongs_to)\s+:#{Regexp.escape(archive_owner_name)}\b/)
            explicit_columns = archive_columns.all? { |column| source.match?(/\bt\.\w+\s+:#{Regexp.escape(column)}\b/) }
            compatible = (expected_reference || explicit_columns) && source.include?(":password_digest") && source.include?(":created_at")
            compatible &&= source.match?(/polymorphic:\s*true/) if polymorphic?
            compatible &&= !source.match?(/polymorphic:\s*true/) unless polymorphic?
            unless polymorphic?
              targets = source.scan(/(?:foreign_key\s+:|to_table:\s*:)([a-z_][a-z0-9_]*)/).flatten
              compatible &&= targets.empty? || targets.include?(model_metadata.table_name)
            end
            raise Thor::Error, "Pending password_archives migration is incompatible with this owner; edit that migration explicitly." unless compatible
          end
        end
      end

      def create_models
        template "password_archive_model.rb.tt", "app/models/password_archive.rb" unless File.file?(File.join(destination_root, "app/models/password_archive.rb"))
      end

      def configure_account
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)

        contents = File.read(path)
        wiring = +"\n"
        wiring << "  include Vouch::Authenticatable\n" unless contents.include?("include Vouch::Authenticatable")
        declarations = contents.scan(/authenticates_with[^\n]*(?:\n[ \t]+:[^\n]*)*/)
        wiring << "  authenticates_with :password_trackable\n" unless declarations.any? { |line| line.match?(/:password_trackable\b/) }
        association = polymorphic? ? "  has_many :password_archives, as: :owner, dependent: :destroy\n" : "  has_many :password_archives, #{model_metadata.association_options(archive_owner_name)}, dependent: :destroy\n"
        wiring << association unless contents.include?("has_many :password_archives")
        return if wiring == "\n"

        inject_model_code(path, model_metadata, wiring)
      end

      def primary_key_type
        options[:primary_key_type].presence
      end

      def create_feature_migration
        validate_archive_storage
        return existing_archive_table! if schema_table_exists?("password_archives") || pending_archive_migrations.any?
        migration_template "password_archives.rb.tt",
                           "db/migrate/create_password_archives.rb"
      end

      def polymorphic?
        options[:polymorphic]
      end

      def owner_primary_keys
        model_metadata.primary_keys
      end

      def owner_primary_key_types
        model_metadata.primary_key_types
      end

      def archive_index_columns
        columns = polymorphic? ? ["owner_type", "owner_id"] : model_metadata.foreign_keys(archive_owner_name)
        (columns + ["created_at"]).inspect
      end

      def archive_owner_options
        ", #{model_metadata.association_options(archive_owner_name)}"
      end

      def archive_owner_name
        polymorphic? ? "owner" : model_metadata.association_key
      end

      private

      def archive_columns
        ownership = polymorphic? ? %w[owner_type owner_id] : model_metadata.foreign_keys(archive_owner_name)
        ownership + %w[password_digest created_at]
      end

      def existing_archive_table!
        validate_existing_table!("password_archives", archive_columns)
        ownership = polymorphic? ? %w[owner_type owner_id] : model_metadata.foreign_keys(archive_owner_name)
        foreign = polymorphic? ? [] : [{ to_table: model_metadata.table_name, column: ownership, primary_key: owner_primary_keys }]
        repair_schema_constraints("password_archives", required: archive_columns, indexes: [ownership + ["created_at"]], foreign_keys: foreign)
        say_status :identical, "password_archives already exists", :blue
      end

      def schema_table_exists?(table)
        return false unless generating_current_host?
        ActiveRecord::Base.connection.data_source_exists?(table)
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end

      def pending_archive_migrations
        Dir[File.join(destination_root, "db/migrate/*.rb")].select { |path| File.read(path).match?(/create_table\s*(?:\(\s*)?:password_archives\b/) }
      end

      def generating_current_host?
        Rails.respond_to?(:root) && Rails.root.present? &&
          File.expand_path(destination_root) == File.expand_path(Rails.root)
      end

      def validate_existing_table!(table, columns)
        return unless schema_table_exists?(table)
        present = ActiveRecord::Base.connection.columns(table).map(&:name)
        missing = columns - present
        raise Thor::Error, "Existing #{table} is incompatible; missing #{missing.join(', ')}" if missing.any?
      end

      def migration_class_name
        "CreatePasswordArchives"
      end
    end
  end
end
