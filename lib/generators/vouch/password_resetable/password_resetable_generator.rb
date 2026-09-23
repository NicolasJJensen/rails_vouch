# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../route_editor"

module Vouch
  module Generators
    class PasswordResetableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "password_resetable"
      desc "Add password reset token columns to the account table."

      argument :account_scope, type: :string, optional: true, banner: "account_model"
      class_option :model_only, type: :boolean, default: false,
                                desc: "Generate the migration and model wiring only"

      class_option :auth_scope, type: :string, default: nil,
                                desc: "Authentication route scope for optional UI"
      class_option :controller_path, type: :string, default: nil,
                                     desc: "Controller namespace path for optional UI"

      def create_optional_ui
        return if options[:model_only]
        return unless auth_scope_name.present?

        template "password_resets_controller.rb.tt", "app/controllers/#{controller_scope_path}/password_resets_controller.rb" unless File.file?(File.join(destination_root, "app/controllers/#{controller_scope_path}/password_resets_controller.rb"))
        template "password_resets_new.html.erb.tt", "app/views/#{view_scope_path}/password_resets/new.html.erb" unless File.file?(File.join(destination_root, "app/views/#{view_scope_path}/password_resets/new.html.erb"))
        template "password_resets_edit.html.erb.tt", "app/views/#{view_scope_path}/password_resets/edit.html.erb" unless File.file?(File.join(destination_root, "app/views/#{view_scope_path}/password_resets/edit.html.erb"))
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
        return if options[:model_only]
        return unless auth_scope_name.present?

        path = File.join(destination_root, "config/routes.rb")
        wrapper = "Vouch.routes(self) do |auth|\nend\n"
        RouteEditor.ensure_wrapper(path, wrapper) if File.file?(path)
        declaration = "auth.password_resets controller: \"#{controller_scope_path}/password_resets\""
        result = RouteEditor.insert_feature(path, auth_scope_name, declaration)
        if result == :unsafe && File.file?(path)
          scope_block = "auth.scope :#{auth_scope_name}, model: \"#{model_metadata.class_name}\" do\n  #{declaration}\nend\n"
          result = RouteEditor.insert_scope(path, scope_block)
        end
        say_status :route, "added auth.password_resets inside :#{auth_scope_name}", :green if result == :inserted
        say_status :route, "auth.password_resets already exists inside :#{auth_scope_name}", :green if result == :duplicate
        return unless result == :unsafe

        say "Add auth.password_resets inside auth.scope :#{auth_scope_name} in config/routes.rb", :yellow
      end

      def create_delivery
        return unless ui_enabled?

        mailer = File.join(destination_root, "app/mailers/#{mailer_path}.rb")
        view = File.join(destination_root, "app/views/#{mailer_path}/reset.text.erb")
        template "password_reset_mailer.rb.tt", mailer unless File.file?(mailer)
        template "password_reset_mailer_reset.text.erb.tt", view unless File.file?(view)
      end

      private

      def controller_scope_path
        options[:controller_path].presence || inferred_controller_path(model_metadata.class_name, auth_scope_name)
      end

      def view_scope_path
        controller_scope_path.camelize.underscore
      end

      def auth_scope_name
        return options[:auth_scope] if options[:auth_scope].present?

        account_scope.present? ? owner_scope_name : inferred_auth_scope(model_metadata.class_name)
      end

      def account_param_key
        model_metadata.param_key
      end

      def ui_enabled?
        !options[:model_only] && auth_scope_name.present?
      end

      def mailer_class_name
        "#{model_metadata.class_name}PasswordResetMailer"
      end

      def model_metadata
        @model_metadata ||= Vouch::ModelMetadata.new(account_scope.presence || scope)
      end

      def owner_scope_name
        if account_scope.present?
          scope.to_s.demodulize.underscore.singularize
        else
          model_metadata.class_name.demodulize.underscore.singularize
        end
      end

      def mailer_path
        mailer_class_name.underscore
      end
    end
  end
end
