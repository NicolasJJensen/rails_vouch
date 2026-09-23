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

      def migration_class_name
        "CreatePasswordArchives"
      end
    end
  end
end
