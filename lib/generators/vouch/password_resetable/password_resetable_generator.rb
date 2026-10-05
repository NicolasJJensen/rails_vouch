# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../route_editor"
require "ripper"

module Vouch
  module Generators
    class PasswordResetableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "password_resetable"
      desc "Add password reset token columns to the account table."

      argument :account_scope, type: :string, optional: true, banner: "account_model"
      class_option :model_only, type: :boolean, default: false,
                                desc: "Generate the migration and model wiring only"
      class_option :token_strategy, type: :string, enum: %w[signed opaque], default: "signed",
                                    desc: "Reset token storage: signed nonce or opaque digest"

      class_option :auth_scope, type: :string, default: nil,
                                desc: "Authentication route scope for optional UI"
      class_option :controller_path, type: :string, default: nil,
                                     desc: "Controller namespace path for optional UI"

      def initialize(args = [], local_options = {}, config = {})
        @explicit_token_strategy = local_options.key?(:token_strategy) || local_options.key?("token_strategy") ||
          args.any? { |argument| argument.to_s.match?(/\A--token-strategy(?:=|\z)/) }
        super
      end

      def create_feature_migration
        validate_model_configuration!
        validate_reset_column_types!
        changed_strategy = configured_strategy && configured_strategy != selected_token_strategy
        complete = feature_schema_already_declared?("password_resetable") || existing_feature_schema_complete?("password_resetable")
        if complete && !changed_strategy && reset_index_complete?
          say_status :identical, "password_resetable schema already exists", :blue
          return
        end
        migration_template "password_resetable.rb.tt", "db/migrate/#{reset_migration_name}.rb"
      end

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
        if ui_enabled? && contents.match?(/^\s*def deliver_password_reset_token\b/) &&
            !contents.match?(/^\s*def deliver_password_reset_token[^\n]*recipient:/)
          say "Preserved #{model_metadata.model_path}: accept recipient: in deliver_password_reset_token and pass it unchanged to delivery.", :yellow
        end
        wiring = +""
        wiring << "  include Vouch::Authenticatable\n\n" unless contents.include?("include Vouch::Authenticatable")
        declaration = reset_declaration(contents)
        if declaration
          updated = configured_declaration(declaration)
          gsub_file(path, declaration, updated) unless updated == declaration
        else
          wiring << "  authenticates_with :password_resetable, password_resetable: { token_strategy: :#{selected_token_strategy} }\n\n"
        end
        wiring += <<~RUBY if ui_enabled? && !contents.match?(/^\s*def deliver_password_reset_token\b/)
          def deliver_password_reset_token(token, recipient:)
            delivery = #{mailer_class_name}.reset(self, token, recipient: recipient).deliver_later
            raise ActiveJob::EnqueueError, "Password reset delivery was not enqueued" unless delivery
            delivery
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

      def selected_token_strategy
        return options[:token_strategy] if @explicit_token_strategy

        configured_strategy || "signed"
      end

      def validate_reset_column_types!
        expected = feature_column_types("password_resetable")
        declared = pending_feature_column_types
        incompatible = expected.keys.select do |name|
          declared.key?(name) && !migration_column_type_matches?(declared[name], expected[name])
        end
        if generating_current_host? && ActiveRecord::Base.connection.data_source_exists?(table_name)
          actual = ActiveRecord::Base.connection.columns(table_name).index_by(&:name)
          incompatible |= expected.keys.select do |name|
            actual.key?(name) && !database_column_type_matches?(actual[name], expected[name])
          end
        end
        return if incompatible.empty?

        raise Thor::Error, "Existing #{table_name} has incompatible password reset columns: #{incompatible.join(', ')}"
      end

      def feature_column_types(_template_name)
        selected_token_strategy == "signed" ? { "password_reset_nonce" => "string" } :
          { "password_reset_token_digest" => "string", "password_reset_sent_at" => "datetime" }
      end

      def reset_index_complete?
        return true unless selected_token_strategy == "opaque" && generating_current_host?
        connection = ActiveRecord::Base.connection
        !connection.data_source_exists?(table_name) || connection.index_exists?(table_name, :password_reset_token_digest, unique: true)
      end

      def reset_migration_name
        @reset_migration_name ||= begin
          base = "add_#{selected_token_strategy}_password_resetable_to_#{table_name}"
          previous = Dir[File.join(destination_root, "db/migrate/*_#{base}*.rb")].length
          previous.zero? ? base : "#{base}_#{previous + 1}"
        end
      end

      def migration_class_name
        reset_migration_name.camelize
      end

      def configured_strategy
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)
        reset_declaration(File.read(path))&.match(/token_strategy:\s*:(signed|opaque)\b/)&.captures&.first
      end

      def validate_model_configuration!
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)
        declaration = reset_declaration(File.read(path))
        configured_declaration(declaration) if declaration
      end

      def reset_declaration(source)
        tokens = Ripper.lex(source)
        tokens.each_with_index do |(position, type, value, _state), index|
          next unless type == :on_ident && value == "authenticates_with"
          declaration_tokens = tokens[index..].take_while { |token| !%i[on_nl on_semicolon on_comment].include?(token[1]) }
          declaration = declaration_tokens.map { |token| token[2] }.join
          return declaration if declaration.match?(/:password_resetable\b/)
        end
        nil
      end

      def configured_declaration(declaration)
        if declaration.match?(/password_resetable:\s*\{/)
          declaration.sub(/password_resetable:\s*\{([^{}]*)\}/) do |options_hash|
            body = Regexp.last_match(1)
            if body.match?(/token_strategy:/)
              raise Thor::Error, "Set the password_resetable token_strategy explicitly before generation" unless body.match?(/token_strategy:\s*:(signed|opaque)\b/)
              options_hash.sub(/token_strategy:\s*:(signed|opaque)\b/, "token_strategy: :#{selected_token_strategy}")
            else
              "password_resetable: {#{body.rstrip}#{body.strip.empty? ? '' : ','} token_strategy: :#{selected_token_strategy} }"
            end
          end.tap do |updated|
            raise Thor::Error, "Update the existing password_resetable options explicitly before generation" if updated == declaration && !declaration.include?("token_strategy: :#{selected_token_strategy}")
          end
        elsif declaration.match?(/password_resetable:/)
          raise Thor::Error, "Update the existing password_resetable options explicitly before generation"
        else
          suffix = ", password_resetable: { token_strategy: :#{selected_token_strategy} }"
          declaration.rstrip.end_with?(")") ? declaration.sub(/\)\s*\z/, "#{suffix})") : declaration.rstrip + suffix
        end
      end

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

      def password_reset_record_name
        if generating_current_host? && (mapping = Vouch.mappings[auth_scope_name.to_sym]) &&
            mapping.account_class_name.delete_prefix("::") == model_metadata.class_name
          return mapping.parent_scope_name if mapping.membership_scope?
          return model_metadata.param_key if mapping.split_model?
        end

        declaration = route_declaration_for(model_metadata.class_name, auth_scope_name) ||
          route_declaration_for(model_metadata.class_name)
        if declaration&.match?(/\baccount:\s*["']#{Regexp.escape(model_metadata.class_name)}["']/)
          model_metadata.param_key
        else
          parent_scope = declaration&.match(/\baccount_scope:\s*(?::([a-zA-Z_][a-zA-Z0-9_]*)|["']([a-zA-Z_][a-zA-Z0-9_]*)["'])/)
          parent_scope&.captures&.compact&.first || auth_scope_name
        end
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
