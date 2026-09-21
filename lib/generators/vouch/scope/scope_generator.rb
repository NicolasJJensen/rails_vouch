# frozen_string_literal: true

require "rails/generators/base"
require "ripper"
require "digest"
require "rails/generators/active_record"
require "vouch/model_metadata"

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

      ROLES = %i[account identity tenant].freeze
      CONTROLLERS = {
        "sessions"               => "SessionsController",
        "registrations"           => "RegistrationsController",
        "passwords"               => "PasswordsController",
        "user_selections"         => "UserSelectionsController",
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

        template "account.rb.tt", model_metadata(@account_class).model_path
        unless @single_model
          template "identity.rb.tt", model_metadata(@identity_class).model_path
        end
        if @tenant_class
          template "tenant.rb.tt", model_metadata(@tenant_class).model_path
        end
      end

      def create_controllers
        namespace = @generated_scope_name.to_s.pluralize
        route_scope = @generated_scope_name.to_s.singularize
        @account_param_key = model_metadata(@account_class).param_key
        @tenant_param_key = model_metadata(@tenant_class).param_key if @tenant_class
        controller_names = if @single_model
                             %w[sessions registrations]
                           else
                             %w[sessions registrations user_selections]
                           end

        controller_names.each do |name|
          class_name = CONTROLLERS.fetch(name)
          @controller_class = "#{namespace.camelize}::#{class_name}"
          @controller_base = class_name
          @controller_route_scope = route_scope
          template "controller.rb.tt",
                   "app/controllers/#{namespace}/#{name}_controller.rb"
        end
      end

      def create_baseline_views
        namespace = @generated_scope_name.to_s.pluralize
        view_namespace = namespace.camelize.underscore

        template "sessions_new.html.erb.tt", "app/views/#{view_namespace}/sessions/new.html.erb"
        template "registrations_new.html.erb.tt", "app/views/#{view_namespace}/registrations/new.html.erb"
        return if @single_model

        template "user_selections_index.html.erb.tt", "app/views/#{view_namespace}/user_selections/index.html.erb"
      end

      # Emit one migration per table so each can be reviewed, reordered, or
      # squashed independently. Order matters for foreign keys: tenant first,
      # account second, identity last.
      def create_migrations
        if @tenant_class
          migration_template "tenant_migration.rb.tt",
                             "db/migrate/create_#{model_table(@tenant_class)}.rb"
        end

        migration_template "account_migration.rb.tt",
                           "db/migrate/create_#{model_table(@account_class)}.rb"

        unless @single_model
          migration_template "identity_migration.rb.tt",
                             "db/migrate/create_#{model_table(@identity_class)}.rb"
        end
      end

      def show_routes_block
        block = build_routes_block
        if insert_route(block)
          say_status :route, "Added scope to config/routes.rb", :green
        else
          say_status :route, "Add to config/routes.rb (inside Vouch.routes(self)):", :yellow
          say "\n#{block}"
        end
      end

      def show_guidance
        say "\nNext steps:"
        say "- Replace the generated baseline views with host-owned UI and add account validations."
        say "- For tenant scopes, adapt the generated name parameter and required tenant associations to the host schema."
        say "- For optional features, add authenticates_with, the model concern and association, migration, controller and route, delivery hook, and views. Invitations also require Vouch::Invitable::Concern plus belongs_to :inviter (optional) and has_many :invitees on the generated identity model."
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

      def model_metadata(name)
        @model_metadata ||= {}
        @model_metadata[name] ||= Vouch::ModelMetadata.new(name)
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

        settings = %(account: "#{@account_class}", identity: "#{@identity_class}")
        settings += %(, tenant: "#{@tenant_class}") if @tenant_class
        associations = {account_identities: model_association(@identity_class).pluralize,
          identity_account: model_association(@account_class)}
        if @tenant_class
          associations[:identity_tenant] = model_association(@tenant_class)
          associations[:tenant_identities] = model_association(@identity_class).pluralize
        end
        pairs = associations.map { |key, value| "#{key}: :#{value}" }.join(', ')
        <<~RUBY.rstrip
            auth.scope :#{route_scope}, #{settings}, associations: {#{pairs}} do
              auth.sessions
              auth.registrations
              auth.user_selection
            end
        RUBY
      end

      def insert_route(block)
        path = File.join(destination_root, "config/routes.rb")
        return false unless File.file?(path)

        lines = File.readlines(path)
        start = lines.index { |line| line.match?(/Vouch\.routes\(self\)\s+do\s*\|auth\|/) }
        return false unless start

        tokens = Ripper.lex(lines[start..].join)
        depth = 0
        closing_line = nil
        tokens.each do |position, type, value, _state|
          next unless type == :on_kw
          return false if %w[if unless while until for case begin def class module].include?(value)
          depth += 1 if value == 'do'
          if value == 'end'
            depth -= 1
            if depth.zero?
              closing_line = position.first
              break
            end
          end
        end
        return false unless closing_line
        # Ripper positions are one-based relative to the sliced source, while
        # `start` and the insertion index are zero-based line indexes.
        insert_at = start + closing_line - 1
        return false unless lines[insert_at].match?(/\A\s*end\s*(?:#.*)?\z/)

        indent = lines[insert_at][/\A\s*/]
        indented_block = block.lines.map { |line| line.strip.empty? ? line : "#{indent}#{line}" }.join
        lines.insert(insert_at, "#{indented_block}\n")
        File.write(path, lines.join)
        true
      end
    end
  end
end
