# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require "generators/vouch/scope/scope_generator"
require "generators/vouch/install/install_generator"
require "generators/vouch/impersonation/impersonation_generator"
require "generators/vouch/invitations/invitations_generator"
require "generators/vouch/recoverable/recoverable_generator"
require "generators/vouch/password_resetable/password_resetable_generator"
require "generators/vouch/two_factorable/two_factorable_generator"
require "generators/vouch/verifiable/verifiable_generator"
require "generators/vouch/omniauth/omniauth_generator"

RSpec.describe "generated host smoke test", :generated_host do
  def documentation_account_example(path:, containing:)
    documentation = File.read(Rails.root.join("..", "..", path))
    account_example = documentation.scan(/```ruby\n(.*?)```/m).flatten
      .find do |block|
        block.include?("class Account < ApplicationRecord") && block.include?(containing)
      end
    raise "#{path} Account example must be non-empty and include #{containing.inspect}" unless account_example

    account_example
  end

  def documentation_account_oauth_association
    account_example = documentation_account_example(
      path: "docs/oauth.md",
      containing: "has_many :oauth_identities"
    )
    association = account_example[/^  has_many :(?:oauth_identities|omni_auth_identities)(?:,.*)?(?:\n    .*)?$/]

    raise "docs/oauth.md Account example must declare an OAuth identity association" unless association

    association
  end

  around do |example|
    connection = ActiveRecord::Base.connection
    ddl_connection = PG.connect(dbname: ActiveRecord::Base.connection_db_config.database)
    schema = "vouch_generated_#{Process.pid}_#{rand(100_000)}"
    @generated_schema = schema
    previous_search_path = connection.schema_search_path
    previous_member_mapping = Vouch.mappings[:member]
    ddl_connection.exec("CREATE SCHEMA \"#{schema}\"")
    ddl_connection.exec(<<~SQL)
      CREATE TABLE "#{schema}"."schema_migrations" (
        "version" character varying NOT NULL PRIMARY KEY
      )
    SQL
    ddl_connection.exec(<<~SQL)
      CREATE TABLE "#{schema}"."ar_internal_metadata" (
        "key" character varying NOT NULL PRIMARY KEY,
        "value" character varying,
        "created_at" timestamp(6) NOT NULL,
        "updated_at" timestamp(6) NOT NULL
      )
    SQL
    connection.schema_search_path = schema

    example.run
  ensure
    if previous_member_mapping
      Vouch.mappings[:member] = previous_member_mapping
    else
      Vouch.deregister_mapping(:member)
    end
    Object.send(:remove_const, :Member) if Object.const_defined?(:Member, false)
    Object.send(:remove_const, :GeneratedApplicationRecord) if Object.const_defined?(:GeneratedApplicationRecord, false)
    connection.schema_search_path = previous_search_path
    ddl_connection.exec("DROP SCHEMA IF EXISTS \"#{schema}\" CASCADE")
    connection.schema_cache.clear!
    ddl_connection.close
  end

  %i[single custom namespaced tenant readme].each do |variant|
  it "migrates, boots, and authenticates a #{variant} generated host", use_transactional_fixtures: false do
    directory = Dir.mktmpdir("vouch-generated-host")
    suffix = "#{Process.pid}#{rand(100_000)}"
    scope_name = "generated_members_#{suffix}"
    model_name = if variant == :readme
                   "User"
                 elsif variant == :namespaced
                   "Generated#{suffix}::Member"
                 else
                   "GeneratedMember#{suffix}"
                 end
    owner_name = if variant == :readme
                   "Account"
                 elsif variant == :namespaced
                   "Generated#{suffix}::Owner"
                 else
                   "GeneratedOwner#{suffix}"
                 end
    tenant_name = "GeneratedTenant#{suffix}" if variant == :tenant
    path_name = scope_name.pluralize
    namespace = path_name.camelize
    view_path = namespace.underscore
    owner_table = Vouch::ModelMetadata.new(owner_name).table_name
    route_scope = scope_name.singularize

    begin
      write_file(directory, "config/boot.rb", <<~RUBY)
        ENV["BUNDLE_GEMFILE"] ||= #{ENV.fetch("BUNDLE_GEMFILE", File.expand_path("../../Gemfile", __dir__)).inspect}
        require "bundler/setup"
      RUBY
      write_file(directory, "config/application.rb", <<~RUBY)
        require_relative "boot"
        require "logger"
        require "rails/all"
        Bundler.require(*Rails.groups)
        require "rails_vouch"

        module GeneratedHost
          class Application < Rails::Application
            config.load_defaults 8.0
            config.root = File.expand_path("..", __dir__)
            config.secret_key_base = "generated-host-smoke-test-secret"
            config.api_only = false
            config.eager_load = false
            config.session_store :cookie_store, key: "_generated_host_session"
            config.action_controller.allow_forgery_protection = false
            config.after_initialize do
              ActiveRecord::Base.connection.schema_search_path = ENV.fetch("GENERATED_SCHEMA")
            end
          end
        end
      RUBY
      write_file(directory, "config/environment.rb", <<~RUBY)
        require_relative "application"
        Rails.application.initialize!
      RUBY
      write_file(directory, "config/environments/test.rb", <<~RUBY)
        Rails.application.configure do
          config.cache_classes = true
          config.eager_load = false
          config.action_controller.allow_forgery_protection = false
        end
      RUBY
      write_file(directory, "config/database.yml", <<~YAML)
        test:
          adapter: postgresql
          database: vouch_test
          encoding: unicode
          schema_search_path: "#{@generated_schema},public"
      YAML
      write_file(directory, "config/routes.rb", <<~RUBY)
        Rails.application.routes.draw do
          root "#{path_name}/dashboard#show"
        end
      RUBY
      write_file(directory, "app/models/application_record.rb", <<~RUBY)
        class ApplicationRecord < ActiveRecord::Base
          self.abstract_class = true
        end
      RUBY
      write_file(directory, "app/controllers/application_controller.rb", <<~RUBY)
        class ApplicationController < ActionController::Base
        end
      RUBY
      write_file(directory, "app/controllers/#{path_name}/dashboard_controller.rb", <<~RUBY)
        class #{namespace}::DashboardController < ApplicationController
          before_action :authenticate_#{route_scope}!

          def show
            render plain: current_#{route_scope}_account.email_address
          end
        end
      RUBY
      write_file(directory, "Rakefile", <<~RUBY)
        require_relative "config/application"
        Rails.application.load_tasks
      RUBY

      install_generator = Vouch::Generators::InstallGenerator.new([])
      install_generator.destination_root = directory
      Dir.chdir(directory) { install_generator.invoke_all }

      arguments = if variant == :single
                    [scope_name, model_name]
                  elsif variant == :tenant
                    [scope_name, "#{owner_name}:account", "#{model_name}:identity", "#{tenant_name}:tenant"]
                  else
                    [scope_name, "#{owner_name}:account", "#{model_name}:identity"]
                  end
      generator = Vouch::Generators::ScopeGenerator.new(arguments, single_model: variant == :single)
      generator.destination_root = directory
      Dir.chdir(directory) { generator.invoke_all }
      oauth_owner_name = variant == :single ? model_name : owner_name
      owner_path = Vouch::ModelMetadata.new(oauth_owner_name).model_path
      if variant == :readme
        owner_source = File.read(File.join(directory, owner_path))
        write_file(directory, owner_path, owner_source.sub(
          "has_secure_password",
          "has_secure_password\n\n#{documentation_account_oauth_association}"
        ))
      end
      omniauth = Vouch::Generators::OmniauthGenerator.new([oauth_owner_name])
      omniauth.destination_root = directory
      Dir.chdir(directory) { omniauth.invoke_all }
      owner_source = File.read(File.join(directory, owner_path))
      write_file(directory, owner_path, owner_source.sub(
        "has_secure_password",
        "has_secure_password\n\n  authenticates_with :omniauthable"
      ))
      if variant == :single
        feature = Vouch::Generators::VerifiableGenerator.new([model_name.underscore.pluralize])
        feature.destination_root = directory
        Dir.chdir(directory) { feature.invoke_all }

        invitations = Vouch::Generators::InvitationsGenerator.new([model_name.underscore.pluralize],
          single_model: true, auth_scope: route_scope, controller_path: path_name)
        invitations.destination_root = directory
        Dir.chdir(directory) { invitations.invoke_all }

        model_path = Vouch::ModelMetadata.new(model_name).model_path
        model_source = File.read(File.join(directory, model_path))
        write_file(directory, model_path, model_source.sub(
          "include Vouch::Authenticatable",
          <<~RUBY.chomp
            include Vouch::Authenticatable
            include Vouch::Invitable::Concern

            belongs_to :inviter, class_name: "#{model_name}", optional: true
            has_many :invitees, class_name: "#{model_name}", foreign_key: :inviter_id, dependent: :nullify
          RUBY
        ))

        invitations_path = "app/controllers/#{path_name}/invitations_controller.rb"
        invitation_source = File.read(File.join(directory, invitations_path))
        write_file(directory, invitations_path, invitation_source.sub(
          /  def authorize_invitation!\n.*?^  end/m,
          "  def authorize_invitation!\n    true\n  end"
        ))

        routes_path = File.join(directory, "config/routes.rb")
        routes = File.read(routes_path)
        updated_routes = routes.sub(/^([ \t]*)auth\.registrations\n([ \t]*)end\b/) do
          [
            "#{Regexp.last_match(1)}auth.registrations\n",
            "#{Regexp.last_match(1)}auth.invitations\n",
            "#{Regexp.last_match(2)}end"
          ].join
        end
        raise "generated single-model invitation route was not inserted" if updated_routes == routes
        write_file(directory, "config/routes.rb", updated_routes)
      end
      if variant == :namespaced
        feature = Vouch::Generators::RecoverableGenerator.new([owner_name])
        feature.destination_root = directory
        Dir.chdir(directory) { feature.invoke_all }

        FileUtils.rm_f(File.join(directory, "app/controllers/#{path_name}/invitations_controller.rb"))
        invitations = Vouch::Generators::InvitationsGenerator.new(
          [model_name, owner_name],
          auth_scope: route_scope,
          controller_path: path_name
        )
        invitations.destination_root = directory
        Dir.chdir(directory) { invitations.invoke_all }
        password_reset = Vouch::Generators::PasswordResetableGenerator.new([owner_name],
          auth_scope: route_scope, controller_path: path_name)
        password_reset.destination_root = directory
        Dir.chdir(directory) { password_reset.invoke_all }
        credential_name = "#{owner_name.deconstantize}::TwoFactorCredential"
        credential_table = Vouch::ModelMetadata.new(credential_name).table_name
        credential_path = Vouch::ModelMetadata.new(credential_name).model_path
        owner_path = Vouch::ModelMetadata.new(owner_name).model_path
        owner_source = File.read(File.join(directory, owner_path))
        owner_source = owner_source.sub(
          "authenticates_with :omniauthable",
          "authenticates_with :omniauthable, :two_factorable"
        ).sub("has_secure_password", <<~RUBY.chomp)
          has_secure_password

          has_many :two_factor_credentials, class_name: "#{credential_name}", foreign_key: :owner_id
        RUBY
        write_file(directory, owner_path, owner_source)
        write_file(directory, credential_path, <<~RUBY)
          class #{credential_name} < ApplicationRecord
            self.table_name = "#{credential_table}"

            belongs_to :owner, class_name: "#{owner_name}"
            include Vouch::TwoFactorable

            self.two_factor_label_attribute = :label

            def verified?
              true
            end

            def deliver_two_factor_code(code)
              FileUtils.mkdir_p(Rails.root.join("tmp"))
              File.write(Rails.root.join("tmp/two_factor_delivery"), code)
            end
          end
        RUBY
        credential_migration = ActiveRecord::Generators::Base.next_migration_number(File.join(directory, "db/migrate"))
        write_file(directory, "db/migrate/#{credential_migration}_create_#{credential_table}.rb", <<~RUBY)
          class Create#{credential_table.camelize} < ActiveRecord::Migration[8.0]
            def change
              create_table :#{credential_table} do |t|
                t.references :owner, null: false, foreign_key: { to_table: :#{owner_table} }
                t.string :label, null: false
                t.datetime :verified_at, null: false
                t.timestamps
              end
            end
          end
        RUBY
        mfa_account_migration = ActiveRecord::Generators::Base.next_migration_number(File.join(directory, "db/migrate"))
        write_file(directory, "db/migrate/#{mfa_account_migration}_add_two_factor_enabled_to_#{owner_table}.rb", <<~RUBY)
          class AddTwoFactorEnabledTo#{owner_table.camelize} < ActiveRecord::Migration[8.0]
            def change
              add_column :#{owner_table}, :two_factor_enabled, :boolean, default: false, null: false
            end
          end
        RUBY
        two_factor = Vouch::Generators::TwoFactorableGenerator.new([credential_name],
          auth_scope: route_scope, controller_path: path_name)
        two_factor.destination_root = directory
        Dir.chdir(directory) { two_factor.invoke_all }
        routes_path = File.join(directory, "config/routes.rb")
        routes = File.read(routes_path)
        updated_routes = routes.sub(/^([ \t]*)auth\.user_selection\n([ \t]*)end\b/) do
          "#{Regexp.last_match(1)}auth.passwords\n" \
            "#{Regexp.last_match(1)}auth.two_factor\n" \
            "#{Regexp.last_match(1)}auth.user_selection\n" \
            "#{Regexp.last_match(1)}auth.invitations\n" \
            "#{Regexp.last_match(2)}end"
        end
        raise "generated invitation route was not inserted" if updated_routes == routes
        write_file(directory, "config/routes.rb", updated_routes)
        impersonation = Vouch::Generators::ImpersonationGenerator.new([path_name], auth_scope: route_scope)
        impersonation.destination_root = directory
        Dir.chdir(directory) { impersonation.invoke_all }
        # Host-owned non-email identifier recipe: the gem's baseline
        # controllers remain intact, while the host supplies its resolver,
        # permitted parameter, and invitation lookup.
        owner_migration = Dir[File.join(directory, "db/migrate/*_create_#{owner_table}.rb")].fetch(0)
        owner_migration_body = File.read(owner_migration)
          .sub("t.string :email_address, null: false", "t.string :email_address")
          .sub(/(create_table[^\n]*\n)/, "\\1      t.string :login\n")
          .sub(/(    end\n    add_index)/, "    end\n    add_index :#{owner_table}, :login, unique: true\n    add_index")
        File.write(owner_migration, owner_migration_body)
        owner_source = File.read(File.join(directory, owner_path))
        owner_source = owner_source.sub(/^  validates :email_address,.*\n/, "")
        write_file(directory, owner_path, owner_source)
        write_file(directory, "app/models/generated_login_resolver.rb", <<~RUBY)
          class GeneratedLoginResolver < Vouch::LoginResolver::Base
            def valid?(params)
              params[:login].present? || params[:email_address].present?
            end

            def resolve!(params, account_class)
              identifier = params[:login] || params[:email_address]
              account = account_class.find_by(login: identifier.to_s.strip.downcase) ||
                account_class.find_by(email_address: identifier.to_s.strip.downcase)
              account ? success!(account) : fail!
            end
          end
        RUBY
        write_file(directory, "config/initializers/generated_login.rb", <<~RUBY)
          require_dependency Rails.root.join("app/models/application_record").to_s
          require Rails.root.join("app/models/generated_login_resolver").to_s
          module #{owner_name.deconstantize}; end unless defined?(#{owner_name.deconstantize})
          require_dependency Rails.root.join("app/models/#{owner_name.underscore}").to_s
          require_dependency Rails.root.join("app/models/#{model_name.underscore}").to_s
          #{owner_name}.include Vouch::PasswordResetable::Concern
          #{model_name}.include Vouch::Invitable::Concern
          #{model_name}.belongs_to :inviter, class_name: #{model_name.inspect}, optional: true
          #{model_name}.has_many :invitees, class_name: #{model_name.inspect}, foreign_key: :inviter_id, dependent: :nullify

          Vouch.configure do |config|
            config.register_login_resolver GeneratedLoginResolver
          end

          Rails.application.config.after_initialize do
            module #{namespace}; end
            require_dependency Rails.root.join("app/controllers/#{path_name}/passwords_controller").to_s
            require_dependency Rails.root.join("app/controllers/#{path_name}/invitations_controller").to_s
            require_dependency Rails.root.join("app/controllers/#{path_name}/impersonations_controller").to_s

            #{namespace}::PasswordsController.on_password_reset_token_generation do |_account, token|
              FileUtils.mkdir_p(Rails.root.join("tmp"))
              File.write(Rails.root.join("tmp/password_reset_delivery"), token.to_s)
            end

            #{namespace}::InvitationsController.class_eval do
              private

              def authorize_invitation!
                true
              end
            end

            #{namespace}::InvitationsController.on_invitation_token_generation do |_identifier, invitee|
              FileUtils.mkdir_p(Rails.root.join("tmp"))
              File.write(Rails.root.join("tmp/invitation_delivery"), invitee.id.to_s)
            end
          end
        RUBY
        registrations_path = "app/controllers/#{path_name}/registrations_controller.rb"
        write_file(directory, registrations_path, <<~RUBY)
          class #{namespace}::RegistrationsController < Vouch::RegistrationsController
            auth_scope :#{route_scope}

            private

            def account_params
              params.require(auth_mapping.account_param_key).permit(:login, :password, :password_confirmation).tap do |attributes|
                attributes[:login] = attributes[:login].to_s.strip.downcase
              end
            end
          end
        RUBY
      end
      write_file(directory, "app/controllers/#{path_name}/omni_auths_controller.rb", <<~RUBY)
        class #{namespace}::OmniAuthsController < Vouch::OmniAuthsController
          auth_scope :#{route_scope}
        end
      RUBY
      routes_path = File.join(directory, "config/routes.rb")
      routes = File.read(routes_path)
      oauth_routes = routes.sub(/^([ \t]*)auth\.(?:registrations|user_selection)\n/) do
        "#{Regexp.last_match(0)}#{Regexp.last_match(0)[/\A[ \t]*/]}auth.oauth_callbacks\n"
      end
      raise "generated OAuth route was not inserted" if oauth_routes == routes
      write_file(directory, "config/routes.rb", oauth_routes)

      connection_result = run_host(directory, "runner", <<~RUBY)
        puts ActiveRecord::Base.connection.schema_search_path
        puts ActiveRecord::Base.connection.select_values("SELECT schema_name FROM information_schema.schemata WHERE schema_name = '#{ @generated_schema }'")
      RUBY
      expect(connection_result).to include(@generated_schema)

      migration_result = run_host(directory, "runner", <<~RUBY)
        ActiveRecord::Base.connection.schema_search_path = ENV.fetch("GENERATED_SCHEMA")
        ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate").to_s).migrate
        oauth_columns = ActiveRecord::Base.connection.columns("oauth_identities").map(&:name)
        abort "generated OAuth owner column was not migrated" unless oauth_columns.include?(#{Vouch::ModelMetadata.new(variant == :single ? model_name : owner_name).association_key.inspect} + "_id")
          if #{variant == :namespaced}
            columns = ActiveRecord::Base.connection.columns(#{owner_name}.table_name).map(&:name)
            abort "recoverable columns were not migrated" unless columns.include?("recovery_attempts") && columns.include?("recovery_locked_at")
            abort "password reset columns were not migrated" unless columns.include?("password_reset_token_digest") && columns.include?("password_reset_sent_at")
        end
        puts "generated host migration passed"
      RUBY
      expect(migration_result).to include("generated host migration passed")

      login_result = run_host(directory, "runner", <<~RUBY)
        account = #{variant == :single ? model_name : owner_name}.create!(email_address: " Generated@Example.COM ", password: "secret123"#{variant == :namespaced ? ', login: "generated-login"' : ''})
        abort "email was not normalized" unless account.email_address == "generated@example.com"
        unless #{variant == :namespaced}
          duplicate = account.class.new(email_address: " GENERATED@EXAMPLE.COM ", password: "secret123")
          abort "duplicate email was accepted" if duplicate.valid? || !duplicate.errors.added?(:email_address, :taken, value: "generated@example.com")
          blank = account.class.new(email_address: " ", password: "secret123")
          abort "blank email was accepted" if blank.valid? || !blank.errors.of_kind?(:email_address, :blank)
        end
        #{"tenant = #{tenant_name}.create!(name: \"Generated tenant\")" if variant == :tenant}
        #{"#{model_name}.create!(#{owner_name.demodulize.underscore}: account#{", #{Vouch::ModelMetadata.new(tenant_name).association_key}: tenant" if variant == :tenant})" unless variant == :single}
        OauthIdentity.create!(#{Vouch::ModelMetadata.new(variant == :single ? model_name : owner_name).association_key}: account,
          provider: "generated_provider", uid: "generated-oauth")
        oauth_session = ActionDispatch::Integration::Session.new(Rails.application)
        oauth_session.get("/#{path_name}/auth/generated_provider/callback", env: {
          "omniauth.auth" => OmniAuth::AuthHash.new(provider: "generated_provider", uid: "generated-oauth", info: {email: account.email_address})
        })
        abort "OAuth callback status: \#{oauth_session.response.status}" unless oauth_session.response.redirect?
        oauth_session.get("/")
        abort "OAuth callback did not retain the signed-in session" unless oauth_session.response.successful? && oauth_session.response.body.include?(account.email_address)
        if #{variant == :single}
          account.define_singleton_method(:deliver_verification_code) { |code| @delivered_code = code }
          proof = account.start_verification!
          code = account.instance_variable_get(:@delivered_code)
      abort "installed verification failed" unless account.complete_verification!(code, token: proof.token).ok?
      abort "installed verification replayed" if account.reload.complete_verification!(code, token: proof.token).ok?
        end
        session = ActionDispatch::Integration::Session.new(Rails.application)
        if #{variant == :single}
          session.get("/#{path_name}/sign_in", params: {format: :html})
          abort "sign-in form status: \#{session.response.status}" unless session.response.successful?
          abort "sign-in form did not use the resolver parameter" unless session.response.body.include?('name="email_address"')

          session.get("/#{path_name}/sign_up", params: {format: :html})
          abort "registration form status: \#{session.response.status}" unless session.response.successful?
          registration_param_key = #{model_name}.model_name.param_key
          expected_email_input = 'name="' + registration_param_key + '[email_address]"'
          abort "registration form did not use the account parameter key" unless session.response.body.include?(expected_email_input)

          session.post("/#{path_name}/sign_up", params: {
            registration_param_key => {
              email_address: "registered@example.test",
              password: "secret123",
              password_confirmation: "secret123"
            }
          })
          abort "registration form submission status: \#{session.response.status}" unless session.response.redirect?
          session = ActionDispatch::Integration::Session.new(Rails.application)
        end
        if #{variant == :namespaced}
          session.get("/#{path_name}/sign_in", params: { format: :html })
          unless session.response.successful?
            exception = session.response.request.env['action_dispatch.exception']
            abort "sign-in form status: \#{session.response.status}; location=\#{session.response.headers['Location'].inspect}; exception=\#{exception&.class}: \#{exception&.message}; body=\#{session.response.body.to_s[0, 500].inspect}"
          end
          session.get("/#{path_name}/sign_up", params: { format: :html })
          abort "registration form status: \#{session.response.status}" unless session.response.successful?
        end
        if #{variant == :namespaced}
          session.post("/#{path_name}/sign_up", params: { #{owner_name}.model_name.param_key => { login: " Registered-Login ", password: "secret123", password_confirmation: "secret123" } })
          unless session.response.redirect?
            exception = session.response.request.env['action_dispatch.exception']
            abort "custom registration status: \#{session.response.status}; content_type=\#{session.response.media_type.inspect}; body=\#{session.response.body.to_s[0, 1000].inspect}; exception=\#{exception&.class}: \#{exception&.message}; backtrace=\#{exception&.backtrace&.first(10).inspect}"
          end
          registered = #{owner_name}.find_by(login: "registered-login")
          abort "custom registration did not persist login" unless registered
          password_session = ActionDispatch::Integration::Session.new(Rails.application)
          password_session.get("/#{path_name}/password/new", params: { format: :html })
          unless password_session.response.successful?
            exception = password_session.response.request.env["action_dispatch.exception"]
            abort "password reset form status: \#{password_session.response.status}; location=\#{password_session.response.headers['Location'].inspect}; exception=\#{exception&.class}: \#{exception&.message}; body=\#{password_session.response.body.to_s[0, 500].inspect}"
          end
          abort "password reset form did not use the resolver parameter" unless password_session.response.body.include?('name="email_address"')
          password_session.post("/#{path_name}/password", params: { email_address: account.email_address })
          unless password_session.response.redirect?
            request = password_session.response.request
            exception = request.env["action_dispatch.exception"]
            abort "password reset request status: \#{password_session.response.status}; location=\#{password_session.response.headers['Location'].inspect}; body=\#{password_session.response.body.to_s[0, 1000].inspect}; exception=\#{exception&.class}: \#{exception&.message}; backtrace=\#{exception&.backtrace&.first(10).inspect}"
          end
          abort "password reset request did not persist delivery token" unless account.reload.password_reset_token_digest.present?
          delivered_reset_token = File.read(Rails.root.join("tmp/password_reset_delivery")) if File.exist?(Rails.root.join("tmp/password_reset_delivery"))
          abort "password reset delivery hook did not run" unless delivered_reset_token&.length.to_i >= 20
          # Registration signs its browser session in. Start the seed-account
          # sign-in flow in a fresh browser session to avoid redirecting the
          # already-authenticated registered account.
          session = ActionDispatch::Integration::Session.new(Rails.application)
        end
        if #{variant == :tenant}
          session.get("/#{path_name}/sign_up", params: {format: :html})
          abort "tenant registration form status: \#{session.response.status}" unless session.response.successful?
          registration_form = session.response.body[/<form\\b.*?<\\/form>/m]
          abort "tenant registration form was not rendered" unless registration_form
          registration_action = registration_form[/\\baction=\"([^\"]+)\"/, 1]
          registration_method = registration_form[/\\bmethod=\"([^\"]+)\"/, 1]
          registration_fields = registration_form.scan(/<input\\b[^>]*\\bname=\"([^\"]+)\"/).flatten
          account_param_key = #{owner_name}.model_name.param_key
          tenant_param_key = #{tenant_name || "Object"}.model_name.param_key
          expected_fields = [
            "\#{account_param_key}[email_address]",
            "\#{account_param_key}[password]",
            "\#{account_param_key}[password_confirmation]",
            "\#{tenant_param_key}[name]"
          ]
          abort "tenant registration form did not expose its route" unless registration_action && registration_method
          abort "tenant registration form fields changed" unless expected_fields.all? { |field| registration_fields.include?(field) }

          session.public_send(registration_method, registration_action, params: {
            account_param_key => {
              email_address: "tenant-registered@example.test",
              password: "secret123",
              password_confirmation: "secret123"
            },
            tenant_param_key => {name: "Tenant registration"}
          })
          abort "tenant registration form submission status: \#{session.response.status}" unless session.response.redirect?
          registered_account = #{owner_name}.find_by(email_address: "tenant-registered@example.test")
          registered_tenant = #{tenant_name || "Object"}.find_by(name: "Tenant registration")
          generated_mapping = Vouch.mapping_for(:#{route_scope})
          registered_identity = #{model_name}.find_by(
            generated_mapping.account_association => registered_account,
            generated_mapping.identity_tenant_association.name => registered_tenant
          )
          abort "tenant registration did not persist the account, tenant, and identity links" unless registered_account && registered_tenant && registered_identity
          signed_identity = session.response.request.env.fetch("warden").user(:#{route_scope})
          abort "tenant registration did not authenticate the generated identity" unless signed_identity&.id == registered_identity.id
          session = ActionDispatch::Integration::Session.new(Rails.application)
        end
        if #{variant == :custom}
          second_identity = #{model_name}.create!(#{owner_name.demodulize.underscore}: account)

          session.get("/#{path_name}/sign_in", params: { format: :html })
          abort "generated sign-in form status: \#{session.response.status}" unless session.response.successful?
          sign_in_form = session.response.body[/<form\\b.*?<\\/form>/m]
          abort "generated sign-in form was not rendered" unless sign_in_form
          sign_in_action = sign_in_form[/\\baction="([^"]+)"/, 1]
          sign_in_method = sign_in_form[/\\bmethod="([^"]+)"/, 1]
          sign_in_fields = sign_in_form.scan(/<input\\b[^>]*\\bname="([^"]+)"/).flatten
          abort "generated sign-in form did not expose its route" unless sign_in_action && sign_in_method
          abort "generated sign-in form fields changed" unless sign_in_fields.include?("email_address") && sign_in_fields.include?("password")

          session.public_send(sign_in_method, sign_in_action, params: {
            email_address: account.email_address,
            password: "secret123"
          })
          abort "generated sign-in form submission status: \#{session.response.status}" unless session.response.redirect?

          session.get("/#{path_name}/select", params: { format: :html })
          abort "generated identity-selection form status: \#{session.response.status}" unless session.response.successful?
          selection_form = session.response.body[/<form\\b.*?<\\/form>/m]
          abort "generated identity-selection form was not rendered" unless selection_form
          selection_action = selection_form[/\\baction="([^"]+)"/, 1]
          selection_method = selection_form[/\\bmethod="([^"]+)"/, 1]
          identity_values = selection_form.scan(/<input\\b[^>]*\\bname="identity_id"[^>]*\\bvalue="([^"]+)"/).flatten
          abort "generated identity-selection form did not expose its route" unless selection_action && selection_method
          abort "generated identity-selection form did not expose both identities" unless identity_values.sort == [#{model_name}.first.id, second_identity.id].map(&:to_s).sort

          session.public_send(selection_method, selection_action, params: { identity_id: second_identity.id })
          abort "generated identity-selection form submission status: \#{session.response.status}" unless session.response.redirect?
          selected_identity = session.response.request.env.fetch("warden").user(:#{route_scope})
          abort "generated identity-selection form did not authenticate the selected identity" unless selected_identity&.id == second_identity.id
          session.get("/")
          abort "selected identity dashboard status: \#{session.response.status}" unless session.response.successful?
          abort "selected identity session was not retained" unless session.response.body.include?(account.email_address)
          restored_identity = session.response.request.env.fetch("warden").user(:#{route_scope})
          abort "selected identity was not restored from the session" unless restored_identity&.id == second_identity.id
        end
        unless #{variant == :custom}
          session.post("/#{path_name}/sign_in", params: { #{variant == :namespaced ? 'login: account.login' : 'email_address: account.email_address'}, password: "secret123" })
          abort "login status: \#{session.response.status}" unless session.response.redirect?
          session.get("/")
          abort "dashboard status: \#{session.response.status}" unless session.response.successful?
          abort "cookie session was not retained" unless session.response.body.include?(account.email_address)
        end
        if #{variant == :single}
          session.get("/#{path_name}/invitation/new", params: {format: :html})
          abort "single-model invitation form status: \#{session.response.status}" unless session.response.successful?
          abort "single-model invitation form did not use the supported email parameter" unless session.response.body.include?('name="email_address"')
          session.post("/#{path_name}/invitation", params: {email_address: "single-invite@example.test"})
          unless session.response.redirect?
            exception = session.response.request.env["action_dispatch.exception"]
            abort "single-model invitation submission status: \#{session.response.status}; exception=\#{exception&.class}: \#{exception&.message}; body=\#{session.response.body.to_s[0, 500].inspect}"
          end
          invitee = #{model_name}.find_by(email_address: "single-invite@example.test")
          abort "single-model invitation did not persist an invited account" unless invitee&.registration_required? && invitee.invitation_token.present?
        end
        if #{variant == :namespaced}
          raw_reset_token = account.generate_password_reset_token!.value
          password_session.get("/#{path_name}/password/edit", params: { token: raw_reset_token, format: :html })
          abort "password reset edit status: \#{password_session.response.status}; location=\#{password_session.response.headers['Location'].inspect}; body=\#{password_session.response.body.to_s[0, 500].inspect}" unless password_session.response.successful?
          abort "password reset edit form did not nest account parameters" unless password_session.response.body.include?('name="#{Vouch::ModelMetadata.new(owner_name).param_key}[password]"')
          reset_params = { #{owner_name}.model_name.param_key => { password: "replacement123", password_confirmation: "replacement123" } }
          invalid_reset_params = { #{owner_name}.model_name.param_key => { password: "short", password_confirmation: "mismatch" } }
          password_session.patch("/#{path_name}/password", params: invalid_reset_params.merge(token: raw_reset_token))
          abort "invalid password reset status: \#{password_session.response.status}" unless password_session.response.status == 422
          password_session.patch("/#{path_name}/password", params: reset_params.merge(token: raw_reset_token))
          unless password_session.response.redirect?
            exception = password_session.response.request.env['action_dispatch.exception']
            abort "password reset update status: \#{password_session.response.status}; body=\#{password_session.response.body.to_s[0, 1000].inspect}; exception=\#{exception&.class}: \#{exception&.message}; backtrace=\#{exception&.backtrace&.first(10).inspect}"
          end
          reset_account = account.reload
          abort "old password still authenticates" if reset_account.authenticate("secret123")
          abort "replacement password did not authenticate" unless reset_account.authenticate("replacement123")
          credential = #{owner_name.deconstantize}::TwoFactorCredential.create!(owner: reset_account, label: "Authenticator", verified_at: Time.current)
          credential.enable_two_factor!
          reset_account.enable_two_factor!
          reset_login_session = ActionDispatch::Integration::Session.new(Rails.application)
          reset_login_session.post("/#{path_name}/sign_in", params: { login: account.login, password: "replacement123" })
          abort "password reset login status: \#{reset_login_session.response.status}" unless reset_login_session.response.redirect?
          reset_login_session.get("/#{path_name}/two_factor_challenges", params: { format: :html })
          abort "two-factor chooser status: \#{reset_login_session.response.status}" unless reset_login_session.response.successful?
          credential_param = "#{owner_name.deconstantize.underscore.gsub('/', '_')}_two_factor_credential-\#{credential.id}"
          abort "two-factor chooser did not use a typed credential ID" unless reset_login_session.response.body.include?(credential_param)
          reset_login_session.get("/#{path_name}/two_factor_challenges/\#{credential_param}", params: { format: :html })
          abort "two-factor challenge form status: \#{reset_login_session.response.status}" unless reset_login_session.response.successful?
          delivered_code = File.read(Rails.root.join("tmp/two_factor_delivery"))
          reset_login_session.patch("/#{path_name}/two_factor_challenges/\#{credential_param}", params: { code: delivered_code })
          unless reset_login_session.response.redirect?
            exception = reset_login_session.response.request.env["action_dispatch.exception"]
            abort "two-factor challenge submission status: \#{reset_login_session.response.status}; exception=\#{exception&.class}: \#{exception&.message}; body=\#{reset_login_session.response.body.to_s[0, 500].inspect}"
          end
          reset_login_session.get("/")
          abort "two-factor completion did not retain the signed-in session" unless reset_login_session.response.successful?
          abort "custom identifier was not normalized" unless account.reload.login == "generated-login"
          target_account = #{owner_name}.create!(email_address: "impersonated@example.test", login: "impersonated-login", password: "secret123")
          target = #{model_name}.create!(#{owner_name.demodulize.underscore}: target_account)
          reset_login_session.post("/#{path_name}/impersonations/\#{target.id}")
          abort "generated impersonation controller did not deny by default" unless reset_login_session.response.forbidden?
          #{namespace}::ImpersonationsController.class_eval do
            private

            def authorize_impersonation!
              true
            end
          end
          reset_login_session.post("/#{path_name}/impersonations/\#{target.id}")
          abort "authorized impersonation did not redirect" unless reset_login_session.response.redirect?
          reset_login_session.get("/")
          abort "authorized impersonation did not select the target" unless reset_login_session.response.body.include?(target_account.email_address)
          reset_login_session.delete("/#{path_name}/impersonations")
          abort "stopping impersonation did not redirect" unless reset_login_session.response.redirect?
          reset_login_session.get("/")
          abort "stopping impersonation did not restore the operator" unless reset_login_session.response.body.include?(reset_account.email_address)
          reset_login_session.get("/#{path_name}/invitation/new", params: { format: :html })
          abort "invitation status: \#{reset_login_session.response.status}; location=\#{reset_login_session.response.headers['Location'].inspect}; body=\#{reset_login_session.response.body.to_s[0, 500].inspect}" unless reset_login_session.response.successful?
          abort "invitation form did not use the supported email parameter" unless reset_login_session.response.body.include?('name="email_address"')
          reset_login_session.post("/#{path_name}/invitation", params: { email_address: "post-invite@example.test" })
          unless reset_login_session.response.redirect?
            request = reset_login_session.response.request
            exception = request.env["action_dispatch.exception"]
            abort "invitation request status: \#{reset_login_session.response.status}; location=\#{reset_login_session.response.headers['Location'].inspect}; body=\#{reset_login_session.response.body.to_s[0, 1000].inspect}; exception=\#{exception&.class}: \#{exception&.message}; backtrace=\#{exception&.backtrace&.first(10).inspect}"
          end
          generated_mapping = Vouch.mapping_for(:#{route_scope})
          posted_invitee = #{model_name}.pending_invitation.detect do |candidate|
            candidate.public_send(generated_mapping.account_association).email_address == "post-invite@example.test"
          end
          abort "invitation request did not persist invitee" unless posted_invitee
          delivered_invitee_id = File.read(Rails.root.join("tmp/invitation_delivery")) if File.exist?(Rails.root.join("tmp/invitation_delivery"))
          abort "invitation delivery hook did not run for persisted invitee" unless delivered_invitee_id == posted_invitee.id.to_s
          invitation_controller = #{namespace}::InvitationsController.allocate
          invitee = invitation_controller.send(:build_invited_identity, " Invitee@example.test ")
          reused = invitation_controller.send(:build_invited_identity, " invitee@example.test ")
          abort "host invitation identifier recipe failed" unless invitee.email_address == "invitee@example.test" && invitee.registration_required? && reused.id == invitee.id
        end
        puts "generated host login passed"
      RUBY
      expect(login_result).to include("generated host login passed")
    ensure
      FileUtils.rm_rf(directory) if directory
    end
  end
  end

  private

  def write_file(directory, relative_path, contents)
    path = File.join(directory, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def run_host(directory, *arguments)
    script = if arguments.first == "runner"
               arguments.fetch(1)
             end
    command = if script
               [RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e",
                "require './config/environment'; #{script}"]
             else
               [RbConfig.ruby, "-S", "rake", *arguments]
             end
    environment = {
      "BUNDLE_GEMFILE" => ENV.fetch("BUNDLE_GEMFILE", File.expand_path("../../Gemfile", __dir__)),
      "RAILS_ENV" => "test",
      "GENERATED_SCHEMA" => @generated_schema,
      "PGOPTIONS" => "-c search_path=#{@generated_schema}"
    }
    stdout, stderr, status = Open3.capture3(environment, *command, chdir: directory)
    return stdout if status.success?

    raise "generated host command failed (#{arguments.first}):\n#{stdout}\n#{stderr}"
  end
end
