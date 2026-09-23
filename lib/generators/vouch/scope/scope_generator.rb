# frozen_string_literal: true

require "rails/generators/base"
require "digest"
require "rails/generators/active_record"
require "vouch/model_metadata"
require_relative "../route_editor"

module Vouch
  module Generators
    # Generate the models, migration, and routes block for an authentication scope.
    #
    #   bin/rails g vouch:scope users Account:account User:identity
    #   bin/rails g vouch:scope members Member --single-model
    #   bin/rails g vouch:scope users Account:account User:identity Organisation:tenant
    #
    class ScopeGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      argument :scope_name, type: :string, banner: "scope_name"
      argument :class_pairs, type: :array, default: [], banner: "ClassName:role ClassName:role"
      class_option :single_model, type: :boolean, default: false,
                                   desc: "Single-model scope (account == identity)"
      class_option :primary_key_type, type: :string, default: nil,
                                       desc: "Primary key type for generated tables (for example, uuid)"
      class_option :account_scope, type: :string, default: nil,
                                   desc: "Authentication scope name for the generated account mapping"

      ROLES = %i[account identity tenant].freeze
      CONTROLLERS = {
        "sessions"               => "SessionsController",
        "registrations"           => "RegistrationsController",
        "password_resets"         => "PasswordResetsController",
        "two_factor_challenge"   => "TwoFactorChallengeController",
        "two_factor_credentials" => "TwoFactorCredentialsController",
        "invitations"             => "InvitationsController",
        "impersonations"          => "ImpersonationsController",
        "omni_auths"              => "OmniAuthsController"
      }.freeze

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def parse_pairs!
        @models = { account: nil, identity: nil, tenant: nil }

        args = [scope_name, *class_pairs]
        derived_scope = args.first&.include?(":")
        @generated_scope_name = if derived_scope
                                 nil
                               else
                                 args.shift
                               end

        if args.empty?
          raise Thor::Error, "Provide at least one ClassName:role pair (or use --single-model with one ClassName)"
        end

        args.each do |pair|
          class_name, separator, role = pair.rpartition(":")
          if separator.empty? || class_name.end_with?(":")
            class_name, role = pair, nil
          end
          if role.nil? && options[:single_model] && args.length == 1
            @models[:account] = @models[:identity] = class_name
            next
          end

          role ||= class_name.downcase
          role_sym = role.to_sym

          unless ROLES.include?(role_sym)
            raise Thor::Error, "Unknown role '#{role}'. Valid roles: #{ROLES.join(', ')}"
          end

          if @models[role_sym]
            raise Thor::Error, "Duplicate role '#{role}'. Supply each role only once."
          end

          @models[role_sym] = class_name
        end

        if derived_scope
          identity = @models[:identity] || @models[:account]
          @generated_scope_name = identity.to_s.demodulize.underscore.singularize
        end

        if options[:single_model]
          source_class = args.first.to_s.sub(/:(account|identity|tenant)\z/, "")
          @models[:account] = @models[:identity] =
            @models[:account] || @models[:identity] || source_class
        end

        if options[:single_model] && @models[:tenant]
          raise Thor::Error,
                "--single-model does not support a tenant. " \
                "Use Account:account User:identity Organisation:tenant for a split-model scope."
        end

        if @models[:account].nil? || @models[:identity].nil?
          raise Thor::Error, "Need both an Account:account and a User:identity pair (or pass --single-model)"
        end
      end

      def create_models
        @account_class = @models[:account]
        @identity_class = @models[:identity]
        @tenant_class = @models[:tenant]
        @single_model = options[:single_model]
        @existing_models = {
          account: model_file_exists?(@account_class),
          identity: model_file_exists?(@identity_class),
          tenant: model_file_exists?(@tenant_class)
        }

        template "account.rb.tt", model_metadata(@account_class).model_path unless @existing_models[:account]
        unless @single_model
          template "identity.rb.tt", model_metadata(@identity_class).model_path unless @existing_models[:identity]
        end
        if @tenant_class
          template "tenant.rb.tt", model_metadata(@tenant_class).model_path unless @existing_models[:tenant]
        end
        add_existing_associations
      end

      def create_controllers
        namespace = @generated_scope_name.to_s.pluralize
        route_scope = @generated_scope_name.to_s.singularize
        @account_param_key = model_metadata(@account_class).param_key
        @tenant_param_key = model_metadata(@tenant_class).param_key if @tenant_class
        controllers = if @single_model
                        [[namespace, "sessions", "SessionsController", route_scope],
                         [namespace, "registrations", "RegistrationsController", route_scope]]
                      else
                        account_namespace = account_route_scope.to_s.pluralize
                        [[account_namespace, "sessions", "SessionsController", account_route_scope],
                         [account_namespace, "registrations", "RegistrationsController", account_route_scope],
                         [namespace, "sessions", "MembershipSessionsController", route_scope]]
                      end

        controllers.each do |controller_namespace, name, base, controller_scope|
          @controller_class = "#{controller_namespace.camelize}::#{name.camelize}Controller"
          @controller_base = base
          @controller_route_scope = controller_scope
          @account_registration = !@single_model && controller_namespace == account_route_scope.to_s.pluralize && name == "registrations"
          controller_path = "app/controllers/#{controller_namespace}/#{name}_controller.rb"
          template "controller.rb.tt", controller_path unless File.file?(File.join(destination_root, controller_path))
        end
      end

      def create_baseline_views
        namespace = @generated_scope_name.to_s.pluralize
        view_namespace = namespace.camelize.underscore

        if @single_model
          @controller_route_scope = @generated_scope_name.to_s.singularize
          template_unless_exists "sessions_new.html.erb.tt", "app/views/#{view_namespace}/sessions/new.html.erb"
          template_unless_exists "registrations_new.html.erb.tt", "app/views/#{view_namespace}/registrations/new.html.erb"
          return
        end

        account_namespace = account_route_scope.to_s.pluralize
        @controller_route_scope = account_route_scope
        template_unless_exists "sessions_new.html.erb.tt", "app/views/#{account_namespace}/sessions/new.html.erb"
        template_unless_exists "registrations_new.html.erb.tt", "app/views/#{account_namespace}/registrations/new.html.erb"
        @controller_route_scope = @generated_scope_name.to_s.singularize
        template_unless_exists "membership_sessions_new.html.erb.tt", "app/views/#{view_namespace}/sessions/new.html.erb"
      end

      # Emit one migration per table so each can be reviewed, reordered, or
      # squashed independently. Order matters for foreign keys: tenant first,
      # account second, identity last.
      def create_migrations
        if @tenant_class && !@existing_models[:tenant]
          migration_template "tenant_migration.rb.tt",
                             "db/migrate/create_#{model_table(@tenant_class)}.rb"
        end

        unless @existing_models[:account]
          migration_template "account_migration.rb.tt",
                             "db/migrate/create_#{model_table(@account_class)}.rb"
        end

        unless @single_model || @existing_models[:identity]
          migration_template "identity_migration.rb.tt",
                             "db/migrate/create_#{model_table(@identity_class)}.rb"
        end
      end

      def show_routes_block
        path = File.join(destination_root, "config/routes.rb")
        wrapper = <<~RUBY
          Vouch.routes(self) do |auth|
            # Add scopes with `bin/rails g vouch:scope <name> Account:account User:identity`
          end
        RUBY
        RouteEditor.ensure_wrapper(path, wrapper) if File.file?(path)
        results = route_blocks.map { |block| RouteEditor.insert_scope(path, block) }
        result = if results.any? { |value| value == :unsafe }
                   :unsafe
                 elsif results.any? { |value| value == :inserted }
                   :inserted
                 else
                   :duplicate
                 end
        if result == :inserted
          say_status :route, "Added scope to config/routes.rb", :green
        elsif result == :duplicate
          say_status :route, "Scope already exists in config/routes.rb", :green
        else
          say_status :route, "Could not update config/routes.rb automatically; merge this configuration into your Rails routes:", :yellow
          say "\nVouch.routes(self) do |auth|\n#{route_blocks.join("\n").lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join}\nend"
        end
      end

      def show_guidance
        say "\nNext steps:"
        say "- Customize the generated views and email defaults, and add application-specific account validations."
        say "- For tenant scopes, adapt the generated name parameter and required tenant associations to the host schema."
        say "- Follow the feature guides to generate password reset, MFA, OAuth, or invitation support and configure their delivery."
      end

      private

      def primary_key_type
        options[:primary_key_type].presence
      end

      def index_name(table, column)
        name = "index_#{table}_on_#{column}"
        name.bytesize <= 63 ? name : "idx_#{Digest::SHA256.hexdigest(name)[0, 20]}"
      end

      def model_table(name)
        model_metadata(name).table_name
      end

      def model_association(name)
        model_metadata(name).association_key
      end

      def model_primary_key_type(name)
        primary_key_type&.to_sym || model_metadata(name).primary_key_types.values.first
      end

      def model_primary_keys(name)
        model_metadata(name).primary_keys
      end

      def model_has_many_options(name)
        model_metadata(name).association_options
      end

      def model_metadata(name)
        @model_metadata ||= {}
        @model_metadata[name] ||= Vouch::ModelMetadata.new(name)
      end

      def model_file_exists?(name)
        return false unless name

        File.file?(File.join(destination_root, model_metadata(name).model_path))
      end

      def template_unless_exists(source, destination)
        template source, destination unless File.file?(File.join(destination_root, destination))
      end

      def add_existing_associations
        return if @single_model

        add_has_many(@account_class, model_association(@identity_class).pluralize,
                     @identity_class, model_association(@account_class)) if @existing_models[:account]
        if @tenant_class && @existing_models[:tenant]
          add_has_many(@tenant_class, model_association(@identity_class).pluralize,
                       @identity_class, model_association(@tenant_class))
        end
      end

      def add_has_many(owner_class, association, child_class, foreign_key)
        path = File.join(destination_root, model_metadata(owner_class).model_path)
        contents = File.read(path)
        return if contents.match?(/^\s*has_many\s+:#{Regexp.escape(association)}\b/)

        foreign_key = "#{foreign_key}_id" unless foreign_key.to_s.end_with?("_id")
        inject_into_class(path, model_metadata(owner_class).declaration_name(contents)) do
          "\n  has_many :#{association}, class_name: \"#{child_class}\", #{model_has_many_options(owner_class)}\n"
        end
      end

      def build_routes_block
        route_scope = @generated_scope_name.to_s.singularize
        if options[:single_model]
          return <<~RUBY.rstrip
              auth.scope :#{route_scope}, model: "#{@models[:identity]}" do
                auth.sessions
                auth.registrations
              end
          RUBY
        end

        settings = %(account_scope: :#{account_route_scope}, identity: "#{@identity_class}")
        settings += %(, tenant: "#{@tenant_class}") if @tenant_class
        <<~RUBY.rstrip
            auth.scope :#{account_route_scope}, model: "#{@account_class}" do
              auth.sessions
              auth.registrations
            end
            auth.scope :#{route_scope}, #{settings} do
              auth.sessions
            end
        RUBY
      end

      def route_blocks
        return [build_routes_block] if options[:single_model]

        route_scope = @generated_scope_name.to_s.singularize
        settings = %(account_scope: :#{account_route_scope}, identity: "#{@identity_class}")
        settings += %(, tenant: "#{@tenant_class}") if @tenant_class
        [
          <<~RUBY.rstrip,
            auth.scope :#{account_route_scope}, model: "#{@account_class}" do
              auth.sessions
              auth.registrations
            end
          RUBY
          <<~RUBY.rstrip
            auth.scope :#{route_scope}, #{settings} do
              auth.sessions
            end
          RUBY
        ]
      end

      def account_route_scope
        inferred = if defined?(Vouch::Mapping)
                     Vouch::Mapping.inferred_scope_name(model: @account_class)
                   else
                     @account_class.to_s.underscore.tr("/", "_").to_sym
                   end
        (options[:account_scope].presence || inferred || :account).to_sym
      end
    end
  end
end
