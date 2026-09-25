# frozen_string_literal: true

require "rails/generators/base"
require "vouch/model_metadata"
require_relative "../feature_base"
require_relative "../recoverable/recoverable_generator"
require_relative "../backup_codes/backup_codes_generator"

module Vouch
  module Generators
    # Public entry point for both kinds of recovery codes.  Account-owned
    # codes recover a pending account MFA challenge; credential-owned codes
    # are attached to one TwoFactorable credential.  They intentionally share
    # the same name and single-use replacement semantics.
    class RecoveryCodesGenerator < Rails::Generators::Base
      argument :scope, type: :string, banner: "AccountOrCredential"
      class_option :owner, type: :string, default: nil,
                           desc: "Owner account model for credential-owned recovery codes"
      class_option :primary_key_type, type: :string, default: nil
      class_option :auth_scope, type: :string, default: nil,
                                  desc: "Authentication scope that owns the recovery-code pages"
      class_option :controller_path, type: :string, default: nil,
                                       desc: "Controller namespace path for recovery-code pages"

      desc "Generate account-owned or credential-owned recovery codes."

      def generate_recovery_codes
        validate_owner! if options[:owner].present?
        generator_class = options[:owner].present? ? BackupCodesGenerator : RecoverableGenerator
        generator = generator_class.new([scope], {primary_key_type: options[:primary_key_type]}.compact)
        generator.destination_root = destination_root
        generator.invoke_all
      end

      # Recovery-code management is useful even when the two-factor generator
      # ran before this feature existed.  Copy the small host UI here instead
      # of requiring a destructive rerun of the MFA generator.
      def create_recovery_ui
        @recovery_controller_path = options[:controller_path].presence || inferred_controller_path(recovery_owner_model, auth_scope_name)
        @recovery_view_path = @recovery_controller_path.camelize.underscore
        @recovery_route_prefix = inferred_route_helper_prefix
        source = File.expand_path("../two_factorable/templates", __dir__)
        template_from(source, "recovery_codes_controller.rb.tt", "app/controllers/#{@recovery_controller_path}/recovery_codes_controller.rb")
        template_from(source, "recovery_codes_show.html.erb.tt", "app/views/#{@recovery_view_path}/recovery_codes/show.html.erb")
        template_from(source, "two_factor_challenge_recovery.html.erb.tt", "app/views/#{@recovery_view_path}/two_factor_challenge/recovery.html.erb")
      end

      private

      def validate_owner!
        credential = Vouch::ModelMetadata.new(scope)
        path = File.join(destination_root, credential.model_path)
        return unless File.file?(path)

        source = File.read(path)
        owner = Regexp.escape(options[:owner].to_s)
        conventional = options[:owner].to_s.demodulize.underscore
        matches_owner = source.match?(/belongs_to\s*(?:\(\s*)?:#{Regexp.escape(conventional)}\b/) ||
          source.match?(/belongs_to[^\n]+class_name:\s*["']#{owner}["']/)
        return if matches_owner

        raise Thor::Error, "#{credential.class_name} must belong_to #{options[:owner]} to own credential recovery codes"
      end

      def scope_metadata
        @scope_metadata ||= Vouch::ModelMetadata.new(scope)
      end

      def recovery_owner_model
        options[:owner].presence || scope_metadata.class_name
      end

      def auth_scope_name
        return options[:auth_scope] if options[:auth_scope].present?

        declaration = route_declaration_for(recovery_owner_model)
        declaration&.match(/\.(?:scope|membership)\s+:([a-zA-Z_][a-zA-Z0-9_]*)/)&.captures&.first ||
          recovery_owner_model.underscore.tr("/", "_")
      end

      def inferred_controller_path(model_name, selected_scope)
        declaration = route_declaration_for(model_name, selected_scope) || route_declaration_for(model_name)
        declaration&.match(/\bpath:\s*["']([^"']+)["']/)&.captures&.first || selected_scope.to_s.pluralize
      end

      def inferred_route_helper_prefix
        declaration = route_declaration_for(recovery_owner_model, auth_scope_name)
        declaration&.match(/\bas:\s*(?:["']([^"']+)["']|:([a-zA-Z_][a-zA-Z0-9_]*))/)&.captures&.compact&.first || auth_scope_name
      end

      def route_declaration_for(model_name, selected_scope = nil)
        path = File.join(destination_root, "config/routes.rb")
        return unless File.file?(path)

        declarations = File.read(path).lines.select { |line| line.match?(/\.(?:scope|membership)\b/) }
        matches = if selected_scope
          declarations.select { |line| line.match?(/\.(?:scope|membership)\s+:#{Regexp.escape(selected_scope.to_s)}\b/) }
        else
          declarations.select { |line| line.match?(/\b(?:model|identity|account):\s*["']#{Regexp.escape(model_name)}["']/) }
        end
        raise Thor::Error, "Several authentication scopes use #{model_name}; pass --auth-scope" if matches.length > 1

        matches.first
      end

      def controller_scope_path
        @recovery_controller_path
      end

      def view_scope_path
        @recovery_view_path
      end

      def route_helper_prefix
        @recovery_route_prefix
      end

      def template_from(source, template_name, target)
        return if File.file?(File.join(destination_root, target))

        self.class.source_root(source)
        template template_name, target
      end
    end
  end
end
