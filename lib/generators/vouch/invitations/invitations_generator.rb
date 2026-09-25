# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../route_editor"

module Vouch
  module Generators
    # Adds invitation columns to the identity table and writes a host-app
    # controller that supplies the required `build_invited_account` hook.
    #
    #   bin/rails g vouch:invitations users Account
    #   bin/rails g vouch:invitations members --single-model
    #
    class InvitationsGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "invitations"
      desc "Add invitation columns to the identity table and write a host controller override."

      # `scope` is inherited from FeatureBase
      argument :account_class, type: :string, optional: true,
                                banner: "AccountClass (optional override for split-model)"

      class_option :single_model, type: :boolean, default: false,
                                   desc: "Use the scoped model as both account and identity"
      class_option :auth_scope, type: :string, default: nil,
                                desc: "Vouch route scope for the generated controller"
      class_option :controller_path, type: :string, default: nil,
                                     desc: "Controller namespace path used by the authentication routes"

      class_option :account, type: :string, default: nil,
                             desc: "Credentials account model for a split-model setup"

      class_option :model_only, type: :boolean, default: false

      def validate_account_class!
        return if options[:single_model]
        return if invitation_account_class.present?

        raise Thor::Error,
              "Could not infer the credentials account from config/routes.rb. " \
              "Pass --account Account (or the legacy second AccountClass argument)."
      end

      def create_registration_migration
        name = "add_registration_required_to_#{registration_table_name}"
        return if Dir.glob(File.join(destination_root, "db/migrate/*_#{name}.rb")).any?

        migration_template "registration.rb.tt", "db/migrate/#{name}.rb"
      end

      def create_invitations_controller
        return if options[:model_only]
        path = File.join(destination_root, "app/controllers/#{controller_scope_path}/invitations_controller.rb")
        template "invitations_controller.rb.tt", path unless File.file?(path)
      end

      def create_invitations_view
        return if options[:model_only]
        path = File.join(destination_root, "app/views/#{view_scope_path}/invitations/new.html.erb")
        template "invitations_new.html.erb.tt", path unless File.file?(path)
      end

      def configure_model
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)
        contents = File.read(path)
        wiring = +"\n"
        wiring << "  include Vouch::Invitable::Concern\n" unless contents.include?("include Vouch::Invitable::Concern")
        wiring << "  belongs_to :inviter, class_name: \"#{identity_class_name}\", #{model_metadata.association_options("inviter")}, optional: true\n" unless contents.include?("belongs_to :inviter")
        wiring << "  has_many :invitees, class_name: \"#{identity_class_name}\", #{model_metadata.association_options("inviter")}, dependent: :nullify\n" unless contents.include?("has_many :invitees")
        inject_into_class(path, model_metadata.declaration_name(contents)) { wiring } unless wiring == "\n"
      end

      def configure_routes
        return if options[:model_only]
        path = File.join(destination_root, "config/routes.rb")
        return unless File.file?(path)
        RouteEditor.ensure_wrapper(path, "Vouch.routes(self) do |auth|\nend\n")
        declaration = "auth.invitations controller: \"#{controller_scope_path}/invitations\""
        result = RouteEditor.insert_feature(path, auth_scope_name, declaration)
        if result == :unsafe && options[:single_model]
          result = RouteEditor.insert_scope(path, "auth.scope :#{auth_scope_name}, model: \"#{identity_class_name}\" do\n  #{declaration}\nend\n")
        end
        say "Add auth.invitations inside auth.scope :#{auth_scope_name} in config/routes.rb", :yellow if result == :unsafe
      end

      def create_delivery
        return if options[:model_only]
        mailer_path = File.join(destination_root, "app/mailers/vouch_invitation_mailer.rb")
        template "invitation_mailer.rb.tt", mailer_path unless File.file?(mailer_path)
        view_path = File.join(destination_root, "app/views/vouch_invitation_mailer/invitation.text.erb")
        template "invitation_mailer.text.erb.tt", view_path unless File.file?(view_path)
      end

      private

      def registration_table_name
        options[:single_model] ? table_name : Vouch::ModelMetadata.new(account_class).table_name
      end

      def migration_class_name
        "AddInvitationsTo#{table_name.camelize}"
      end

      def scope_module
        controller_scope_path.camelize
      end

      def identity_class_name
        model_metadata.class_name
      end

      def invitation_account_class
        return identity_class_name if options[:single_model]
        return options[:account] if options[:account].present?
        return account_class if account_class.present?

        inferred_account_class
      end

      def controller_scope_path
        options[:controller_path].presence ||
          [model_metadata.class_name.deconstantize,
           model_metadata.class_name.demodulize.pluralize].compact_blank.join("::").underscore
      end

      def view_scope_path
        controller_scope_path.camelize.underscore
      end

      def auth_scope_name
        options[:auth_scope].presence || model_metadata.class_name.demodulize.underscore.singularize
      end

      def inferred_account_class
        routes = File.join(destination_root, "config/routes.rb")
        return unless File.file?(routes)

        source = File.read(routes)
        declaration = source.lines.find { |line| line.match?(/\.scope\s+:#{Regexp.escape(auth_scope_name.to_s)}\b/) }
        return unless declaration
        return Regexp.last_match(1) if declaration.match(/\baccount:\s*["']([^"']+)["']/)

        parent = declaration[/\baccount_scope:\s*:(\w+)/, 1]
        return unless parent
        parent_line = source.lines.find { |line| line.match?(/\.scope\s+:#{Regexp.escape(parent)}\b/) }
        parent_line&.match(/\bmodel:\s*["']([^"']+)["']/)&.captures&.first
      end
    end
  end
end
