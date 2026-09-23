# frozen_string_literal: true

require_relative "../feature_base"
require_relative "../route_editor"

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
      class_option :model_only, type: :boolean, default: false
      class_option :subject, type: :array, default: [],
                             desc: "Credential subject attribute(s)"

      def initialize(args = [], options = {}, config = {})
        super
        validate_optional_ui!
      end

      def create_optional_ui
        return if options[:model_only]
        return unless auth_scope_name.present?

        template_unless_exists "two_factor_challenge_controller.rb.tt", "app/controllers/#{controller_scope_path}/two_factor_challenge_controller.rb"
        template_unless_exists "two_factor_challenge_index.html.erb.tt", "app/views/#{view_scope_path}/two_factor_challenge/index.html.erb"
        template_unless_exists "two_factor_challenge_show.html.erb.tt", "app/views/#{view_scope_path}/two_factor_challenge/show.html.erb"
        template_unless_exists "two_factor_credentials_controller.rb.tt", "app/controllers/#{controller_scope_path}/two_factor_credentials_controller.rb"
        template_unless_exists "two_factor_credentials_new.html.erb.tt", "app/views/#{view_scope_path}/two_factor_credentials/new.html.erb"
        template_unless_exists "two_factor_credentials_index.html.erb.tt", "app/views/#{view_scope_path}/two_factor_credentials/index.html.erb"
      end

      def configure_model
        path = File.join(destination_root, model_metadata.model_path)
        return unless File.file?(path)
        contents = File.read(path)
        wiring = +"\n"
        credential = credential_model?
        if credential
          wiring << "  include Vouch::Verifiable\n" unless contents.include?("include Vouch::Verifiable")
          wiring << "  include Vouch::TwoFactorable\n" unless contents.include?("include Vouch::TwoFactorable")
          if options[:subject].any? && !contents.include?("verifiable_subject_attribute")
            value = options[:subject].length == 1 ? ":#{options[:subject].first}" : "[#{options[:subject].map { |a| ":#{a}" }.join(", ")}]"
            wiring << "  self.verifiable_subject_attribute = #{value}\n"
          end
          wiring << "\n  def deliver_verification_code(_code)\n    raise NotImplementedError, \"Implement verification delivery for #{model_metadata.class_name}\"\n  end\n" unless contents.include?("def deliver_verification_code")
          wiring << "\n  def deliver_two_factor_code(_code)\n    raise NotImplementedError, \"Implement two-factor delivery for #{model_metadata.class_name}\"\n  end\n" unless contents.include?("def deliver_two_factor_code")
        else
          wiring << "  include Vouch::Authenticatable\n" unless contents.include?("include Vouch::Authenticatable")
          wiring << "  authenticates_with :two_factorable\n" unless contents.include?("authenticates_with :two_factorable")
          wiring << "  has_many :#{credential_association_name}, dependent: :destroy\n" if owner_model && !contents.include?("has_many :#{credential_association_name}")
        end
        if options[:subject].any? && !contents.include?("two_factor_label_attribute")
          wiring << "  self.two_factor_label_attribute = :#{options[:subject].first}\n"
        end
        return if wiring == "\n"
        inject_model_code(path, model_metadata, wiring)
        return unless credential

        owner_path = File.join(destination_root, Vouch::ModelMetadata.new(owner_model).model_path)
        return unless File.file?(owner_path)
        owner_contents = File.read(owner_path)
        owner_wiring = +"\n"
        owner_wiring << "  include Vouch::Authenticatable\n" unless owner_contents.include?("include Vouch::Authenticatable")
        owner_wiring << "  authenticates_with :two_factorable\n" unless owner_contents.include?("authenticates_with :two_factorable")
        owner_wiring << "  has_many :#{credential_association_name}, dependent: :destroy\n" unless owner_contents.include?("has_many :#{credential_association_name}")
        inject_model_code(owner_path, Vouch::ModelMetadata.new(owner_model), owner_wiring) unless owner_wiring == "\n"
      end

      def configure_routes
        return if options[:model_only] || auth_scope_name.blank?
        path = File.join(destination_root, "config/routes.rb")
        return unless File.file?(path)
        RouteEditor.ensure_wrapper(path, "Vouch.routes(self) do |auth|\nend\n")
        declaration = "auth.two_factor challenge_controller: \"#{controller_scope_path}/two_factor_challenge\", credentials_controller: \"#{controller_scope_path}/two_factor_credentials\""
        result = RouteEditor.insert_feature(path, auth_scope_name, declaration)
        if result == :unsafe
          result = RouteEditor.insert_scope(path, "auth.scope :#{auth_scope_name}, model: \"#{owner_model}\" do\n  #{declaration}\nend\n")
        end
        say "Add auth.two_factor inside auth.scope :#{auth_scope_name} in config/routes.rb", :yellow if result == :unsafe
      end

      def create_owner_migration
        return unless owner_model && owner_model != model_metadata.class_name
        table = Vouch::ModelMetadata.new(owner_model).table_name
        return if Dir[File.join(destination_root, "db/migrate/*two_factor_enabled*#{table}*.rb")].any?
        migration_template "two_factor_owner.rb.tt", "db/migrate/add_two_factor_enabled_to_#{table}.rb"
      end

      def show_enrollment_guidance
        return unless options[:auth_scope].present?

        say "Implement the generated credential delivery methods before enrolling a factor.", :yellow
      end

      private

      def validate_optional_ui!
        unless subject_attributes.all? { |name| name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) }
          raise Thor::Error, "Subject attributes must be model attribute names"
        end
      end

      def template_unless_exists(source, destination)
        template source, destination unless File.file?(File.join(destination_root, destination))
      end

      def controller_scope_path
        options[:controller_path].presence || inferred_controller_path(owner_model.to_s, auth_scope_name)
      end

      def view_scope_path
        controller_scope_path.camelize.underscore
      end

      def auth_scope_name
        return options[:auth_scope] if options[:auth_scope].present?
        inferred_auth_scope(owner_model.to_s)
      end

      def credential_model?
        model_metadata.class_name != owner_model
      end

      def owner_model
        return @owner_model if defined?(@owner_model)
        path = File.join(destination_root, model_metadata.model_path)
        source = File.file?(path) ? File.read(path) : ""
        associations = source.scan(/^\s*belongs_to\s+:([a-z_]+)(?:,\s*class_name:\s*["']([^"']+)["'])?/)
        @owner_model = if associations.empty?
                         model_metadata.class_name
                       elsif associations.length == 1
                         associations.first[1].presence || associations.first[0].classify
                       end
      end

      def credential_association_name
        model_metadata.class_name.demodulize.underscore.pluralize
      end

      def subject_attribute
        options[:subject].first.presence || :e164
      end

      def subject_attributes
        options[:subject].presence || [subject_attribute]
      end

      def permitted_subject_attributes
        subject_attributes.map { |attribute| ":#{attribute}" }.join(", ")
      end

      def verifiable_columns_already_migrated?
        Dir[File.join(destination_root, "db/migrate/*.rb")].any? do |path|
          contents = File.read(path)
          contents.match?(/(?:change_table|create_table)\s+:#{Regexp.escape(table_name)}\b/) &&
            contents.include?("verification_nonce") && contents.include?("verified_at")
        end
      end
    end
  end
end
