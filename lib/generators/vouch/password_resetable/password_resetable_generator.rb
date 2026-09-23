# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../route_editor"

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

      def configure_model
        path = File.join(destination_root, model_metadata.model_path)
        unless File.file?(path)
          say_status :skip, "#{path} not found — add Vouch::PasswordResetable manually", :yellow
          return
        end

        contents = File.read(path)
        wiring = +""
        wiring << "  include Vouch::Authenticatable\n\n" unless contents.include?("include Vouch::Authenticatable")
        wiring << "  authenticates_with :password_resetable\n\n" unless contents.include?("authenticates_with :password_resetable")
        wiring += <<~RUBY if ui_enabled? && !contents.match?(/^\s*def deliver_password_reset_token\b/)
          def deliver_password_reset_token(token)
            #{mailer_class_name}.reset(self, token).deliver_later
          end

        RUBY
        return if wiring.empty?

        if contents.match?(/^\s*include Vouch::Authenticatable\s*$/)
          inject_into_file(path, after: /^\s*include Vouch::Authenticatable\s*\n/) { "\n#{wiring}" }
        else
          inject_into_class(path, model_metadata.declaration_name(contents)) { "\n#{wiring}" }
        end
      end

      def configure_routes
        return unless options[:auth_scope].present?

        path = File.join(destination_root, "config/routes.rb")
        result = RouteEditor.insert_feature(path, options[:auth_scope], "auth.passwords")
        say_status :route, "added auth.passwords inside :#{options[:auth_scope]}", :green if result == :inserted
        say_status :route, "auth.passwords already exists inside :#{options[:auth_scope]}", :green if result == :duplicate
        return unless result == :unsafe

        say "Add auth.passwords inside auth.scope :#{options[:auth_scope]} in config/routes.rb", :yellow
      end

      def create_delivery
        return unless ui_enabled?

        template "password_reset_mailer.rb.tt", "app/mailers/#{mailer_path}.rb"
        template "password_reset_mailer_reset.text.erb.tt", "app/views/#{mailer_path}/reset.text.erb"
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

      def ui_enabled?
        options[:auth_scope].present? && options[:controller_path].present?
      end

      def mailer_class_name
        "#{model_metadata.class_name}PasswordResetMailer"
      end

      def mailer_path
        mailer_class_name.underscore
      end
    end
  end
end
