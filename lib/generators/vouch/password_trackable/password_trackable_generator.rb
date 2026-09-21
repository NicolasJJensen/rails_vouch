# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class PasswordTrackableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "password_trackable"
      desc "Create the password_archives table for password history tracking."

      def primary_key_type
        options[:primary_key_type].presence
      end

      def create_feature_migration
        migration_template "password_archives.rb.tt",
                           "db/migrate/create_password_archives.rb"
      end

      private

      def migration_class_name
        "CreatePasswordArchives"
      end
    end
  end
end
