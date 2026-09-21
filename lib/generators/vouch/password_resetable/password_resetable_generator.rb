# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class PasswordResetableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "password_resetable"
      desc "Add password reset token columns to the account table."

      class_option :auth_scope, type: :string, default: nil,
                                desc: "Authentication route scope for optional UI"
      class_option :controller_path, type: :string, default: nil,
                                     desc: "Controller namespace path for optional UI"

      def initialize(args = [], options = {}, config = {})
        super
        validate_optional_ui!
      end

      def create_optional_ui
        return unless options[:auth_scope].present?

        template "passwords_controller.rb.tt", "app/controllers/#{controller_scope_path}/passwords_controller.rb"
        template "passwords_new.html.erb.tt", "app/views/#{view_scope_path}/passwords/new.html.erb"
        template "passwords_edit.html.erb.tt", "app/views/#{view_scope_path}/passwords/edit.html.erb"
      end

      private

      def validate_optional_ui!
        return if options[:auth_scope].blank? && options[:controller_path].blank?
        return if options[:auth_scope].present? && options[:controller_path].present?

        raise Thor::Error, "Pass --auth-scope and --controller-path together to generate password reset UI."
      end

      def controller_scope_path
        options[:controller_path]
      end

      def view_scope_path
        controller_scope_path.camelize.underscore
      end

      def auth_scope_name
        options[:auth_scope]
      end

      def account_param_key
        model_metadata.param_key
      end
    end
  end
end
