# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class PasswordTrackableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "password_trackable"
      desc "Create the password_archives table for password history tracking."

      class_option :polymorphic, type: :boolean, default: false,
                                  desc: "Use a polymorphic archive owner"

      def create_models
        template "password_archive_model.rb.tt", "app/models/password_archive.rb" unless File.file?(File.join(destination_root, "app/models/password_archive.rb"))
      end

      def configure_account
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)

        contents = File.read(path)
        wiring = +"\n"
        wiring << "  include Vouch::Authenticatable\n" unless contents.include?("include Vouch::Authenticatable")
        wiring << "  authenticates_with :password_trackable\n" unless contents.include?("authenticates_with :password_trackable")
        association = options[:polymorphic] ? "  has_many :password_archives, as: :account, dependent: :destroy\n" : "  has_many :password_archives, #{model_metadata.association_options("account")}, dependent: :destroy\n"
        wiring << association unless contents.include?("has_many :password_archives")
        return if wiring == "\n"

        inject_model_code(path, model_metadata, wiring)
      end

      def primary_key_type
        options[:primary_key_type].presence
      end

      def create_feature_migration
        return existing_archive_table! if schema_table_exists?("password_archives") || pending_table_migration?("password_archives")
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
        columns = polymorphic? ? ["account_type", "account_id"] : model_metadata.foreign_keys("account")
        (columns + ["created_at"]).inspect
      end

      def archive_owner_options
        ", #{model_metadata.association_options('account')}"
      end

      private

      def existing_archive_table!
        validate_existing_table!("password_archives", %w[password_digest created_at])
        say_status :identical, "password_archives already exists", :blue
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
