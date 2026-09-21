# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class TwoFactorableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "two_factorable"
      desc "Add TwoFactorable columns to a model's table."

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

        template "two_factor_challenge_controller.rb.tt", "app/controllers/#{controller_scope_path}/two_factor_challenge_controller.rb"
        template "two_factor_challenge_index.html.erb.tt", "app/views/#{view_scope_path}/two_factor_challenge/index.html.erb"
        template "two_factor_challenge_show.html.erb.tt", "app/views/#{view_scope_path}/two_factor_challenge/show.html.erb"
      end

      def show_enrollment_guidance
        return unless options[:auth_scope].present?

        say "Add #{controller_scope_path.camelize}::TwoFactorCredentialsController and enrollment views for your permitted credential types.", :yellow
      end

      private

      def validate_optional_ui!
        return if options[:auth_scope].blank? && options[:controller_path].blank?
        return if options[:auth_scope].present? && options[:controller_path].present?

        raise Thor::Error, "Pass --auth-scope and --controller-path together to generate two-factor UI."
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
    end
  end
end
