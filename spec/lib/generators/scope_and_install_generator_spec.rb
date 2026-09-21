# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/generators"
require "fileutils"
require "tmpdir"

require "generators/vouch/install/install_generator"
require "generators/vouch/impersonation/impersonation_generator"
require "generators/vouch/invitations/invitations_generator"
require "generators/vouch/omniauth/omniauth_generator"
require "generators/vouch/recoverable/recoverable_generator"
require "generators/vouch/scope/scope_generator"
require "generators/vouch/verifiable/verifiable_generator"

RSpec.describe "Vouch generators" do
  def run_generator(generator_class, args, options = {}, routes: nil)
    directory = Dir.mktmpdir("vouch-generator-spec")
    if routes
      FileUtils.mkdir_p(File.join(directory, "config"))
      File.write(File.join(directory, "config/routes.rb"), routes)
    end

    Dir.chdir(directory) do
      generator = generator_class.new(args, options)
      generator.destination_root = directory
      generator.invoke_all
    end

    directory
  end

  after do
    FileUtils.rm_rf(@generator_directory) if @generator_directory
  end

  it "writes an initializer that calls the public configuration API" do
    @generator_directory = run_generator(Vouch::Generators::InstallGenerator, [])
    initializer = File.read(File.join(@generator_directory, "config/initializers/vouch.rb"))

    expect(initializer).to include("Vouch.configure do |config|")
    expect(initializer).not_to include("Vouch.setup")
    expect(initializer).to include("config.register_login_resolver")
  end

  it "generates a single-model account with the required password contract" do
    @generator_directory = run_generator(
      Vouch::Generators::ScopeGenerator,
      ["members", "Member"],
      { single_model: true }
    )
    model = File.read(File.join(@generator_directory, "app/models/member.rb"))

    expect(model).to include("include Vouch::Authenticatable")
    expect(model).to include("has_secure_password")
    expect(File.read(File.join(@generator_directory, "app/controllers/members/sessions_controller.rb"))).to include(
      "class Members::SessionsController < Vouch::SessionsController"
    )
    expect(File).to exist(File.join(@generator_directory, "db/migrate"))
  end

  it "derives a single-model scope from a ClassName:role argument" do
    @generator_directory = run_generator(
      Vouch::Generators::ScopeGenerator,
      ["Member:account"],
      { single_model: true }
    )
    output = File.read(Dir[File.join(@generator_directory, "app/models/member.rb")].first)

    expect(output).to include("Vouch::Authenticatable")
  end

  it "inserts a generated scope into an existing routes block" do
    @generator_directory = run_generator(
      Vouch::Generators::ScopeGenerator,
      ["members", "Member"],
      { single_model: true },
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
          end
        end
      RUBY
    )
    routes = File.read(File.join(@generator_directory, "config/routes.rb"))

    expect(routes).to include('auth.scope :member, model: "Member"')
  end

  it "adds impersonation to an existing scope and writes a safely denying host controller" do
    @generator_directory = run_generator(
      Vouch::Generators::ImpersonationGenerator,
      ["users"],
      {},
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
            auth.scope :user, account: "Account", identity: "User" do
              auth.sessions
            end
          end
        end
      RUBY
    )

    routes = File.read(File.join(@generator_directory, "config/routes.rb"))
    controller = File.read(File.join(@generator_directory, "app/controllers/users/impersonations_controller.rb"))

    expect(routes).to include("auth.sessions\n      auth.impersonation controller: \"users/impersonations\"")
    expect(controller).to include("class Users::ImpersonationsController < Vouch::ImpersonationsController")
    expect(controller).to include("auth_scope :user")
    expect(controller).to include("head :forbidden")
  end

  it "uses the scope block variable, does not duplicate the route, and preserves an existing controller" do
    routes = <<~RUBY
      Rails.application.routes.draw do
        Vouch.routes(self) do |router|
          router.scope :user, account: "Account", identity: "User" do |scope_routes|
            scope_routes.sessions
          end
        end
      end
    RUBY
    @generator_directory = run_generator(
      Vouch::Generators::ImpersonationGenerator,
      ["portal"],
      { auth_scope: "user" },
      routes: routes
    )
    controller_path = File.join(@generator_directory, "app/controllers/portal/impersonations_controller.rb")
    File.write(controller_path, "# host implementation\n")

    Dir.chdir(@generator_directory) do
      generator = Vouch::Generators::ImpersonationGenerator.new(["portal"], auth_scope: "user")
      generator.destination_root = @generator_directory
      generator.invoke_all
    end

    updated_routes = File.read(File.join(@generator_directory, "config/routes.rb"))

    expect(updated_routes.scan("scope_routes.impersonation").length).to eq(1)
    expect(File.read(controller_path)).to eq("# host implementation\n")
  end

  it "leaves an ambiguous target mapping unchanged while still generating the host controller" do
    @generator_directory = run_generator(
      Vouch::Generators::ImpersonationGenerator,
      ["users"],
      {},
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
            auth.scope :user, account: "Account", identity: "User" do
              auth.sessions
            end
            auth.scope :user, account: "Account", identity: "User" do
              auth.registrations
            end
          end
        end
      RUBY
    )

    routes = File.read(File.join(@generator_directory, "config/routes.rb"))

    expect(routes).not_to include("impersonation")
    expect(File).to exist(File.join(@generator_directory, "app/controllers/users/impersonations_controller.rb"))
  end

  it "leaves a scope with structural control flow unchanged" do
    @generator_directory = run_generator(
      Vouch::Generators::ImpersonationGenerator,
      ["users"],
      {},
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
            auth.scope :user, account: "Account", identity: "User" do
              if Rails.env.production?
                auth.sessions
              end
            end
          end
        end
      RUBY
    )

    routes = File.read(File.join(@generator_directory, "config/routes.rb"))

    expect(routes).not_to include("auth.impersonation")
  end

  it "uses an explicit authentication scope when the controller namespace differs" do
    @generator_directory = run_generator(
      Vouch::Generators::ImpersonationGenerator,
      ["portal"],
      { auth_scope: "user" },
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
            auth.scope :user, account: "Account", identity: "User", path: "portal" do
              auth.sessions
            end
          end
        end
      RUBY
    )

    controller = File.read(File.join(@generator_directory, "app/controllers/portal/impersonations_controller.rb"))

    expect(controller).to include("class Portal::ImpersonationsController < Vouch::ImpersonationsController")
    expect(controller).to include("auth_scope :user")
  end

  it "generates only the baseline routes and controllers for a split-model scope" do
    @generator_directory = run_generator(
      Vouch::Generators::ScopeGenerator,
      ["users", "Account:account", "User:identity"],
      {},
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
          end
        end
      RUBY
    )

    routes = File.read(File.join(@generator_directory, "config/routes.rb"))
    expect(routes).to include("auth.sessions")
    expect(routes).to include("auth.registrations")
    expect(routes).to include("auth.user_selection")
    expect(routes).not_to include("auth.passwords")
    expect(routes).not_to include("auth.two_factor")
    expect(routes).not_to include("auth.invitations")
    expect(routes).not_to include("auth.impersonation")
    expect(routes).not_to include("auth.oauth_callbacks")

    expect(File).to exist(File.join(@generator_directory, "app/controllers/users/sessions_controller.rb"))
    expect(File).to exist(File.join(@generator_directory, "app/controllers/users/registrations_controller.rb"))
    expect(File).to exist(File.join(@generator_directory, "app/controllers/users/user_selections_controller.rb"))
    expect(File.read(File.join(@generator_directory, "app/views/users/sessions/new.html.erb"))).to include("user_session_path")
    expect(File.read(File.join(@generator_directory, "app/views/users/registrations/new.html.erb"))).to include(
      "scope: :account, method: :post"
    )
    expect(File.read(File.join(@generator_directory, "app/views/users/user_selections/index.html.erb"))).to include(
      "radio_button_tag :identity_id"
    )
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/users/passwords_controller.rb"))
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/users/two_factor_challenge_controller.rb"))
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/users/invitations_controller.rb"))
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/users/impersonations_controller.rb"))
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/users/omni_auths_controller.rb"))
  end

  it "generates only sessions and registrations for a single-model scope" do
    @generator_directory = run_generator(
      Vouch::Generators::ScopeGenerator,
      ["members", "Member"],
      { single_model: true },
      routes: <<~RUBY
        Rails.application.routes.draw do
          Vouch.routes(self) do |auth|
          end
        end
      RUBY
    )

    routes = File.read(File.join(@generator_directory, "config/routes.rb"))
    expect(routes).to include("auth.sessions")
    expect(routes).to include("auth.registrations")
    expect(routes).not_to include("auth.user_selection")
    expect(routes).not_to include("auth.passwords")
    expect(File).to exist(File.join(@generator_directory, "app/controllers/members/sessions_controller.rb"))
    expect(File).to exist(File.join(@generator_directory, "app/controllers/members/registrations_controller.rb"))
    expect(File).to exist(File.join(@generator_directory, "app/views/members/sessions/new.html.erb"))
    expect(File).to exist(File.join(@generator_directory, "app/views/members/registrations/new.html.erb"))
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/members/user_selections_controller.rb"))
    expect(File).not_to exist(File.join(@generator_directory, "app/controllers/members/passwords_controller.rb"))
  end

  it "rejects a tenant for a single-model scope before writing artifacts" do
    @generator_directory = Dir.mktmpdir("vouch-generator-spec")
    generator = Vouch::Generators::ScopeGenerator.new(
      ["members", "Member:account", "Organisation:tenant"],
      single_model: true
    )
    generator.destination_root = @generator_directory

    expect {
      Dir.chdir(@generator_directory) { generator.invoke_all }
    }.to raise_error(Thor::Error, /--single-model does not support a tenant/)
    expect(Dir.children(@generator_directory)).to be_empty
  end

  it "generates a tenant name contract only for its generated tenant schema" do
    @generator_directory = run_generator(
      Vouch::Generators::ScopeGenerator,
      ["users", "Account:account", "User:identity", "Organisation:tenant"]
    )

    controller = File.read(File.join(@generator_directory, "app/controllers/users/registrations_controller.rb"))
    view = File.read(File.join(@generator_directory, "app/views/users/registrations/new.html.erb"))

    expect(controller).to include("def registration_tenant_attributes(_account)")
    expect(controller).to include("params.require(:organisation).permit(:name)")
    expect(view).to include('text_field_tag "organisation[name]"')
  end

  it "generates matching auth_data and UUID OAuth columns" do
    @generator_directory = run_generator(
      Vouch::Generators::OmniauthGenerator,
      ["accounts"],
      { primary_key_type: "uuid" }
    )
    migration = File.read(Dir[File.join(@generator_directory, "db/migrate/*oauth_identities.rb")].first)

    expect(migration).to include("type: :uuid")
    expect(migration).to include(":auth_data")
    expect(migration).not_to include(":raw_info")
  end

  it "uses UUID columns for the recoverable owner and recovery rows" do
    @generator_directory = run_generator(
      Vouch::Generators::RecoverableGenerator,
      ["accounts"],
      { primary_key_type: "uuid" }
    )
    migration = File.read(Dir[File.join(@generator_directory, "db/migrate/*recovery_codes.rb")].first)

    expect(migration).to include("create_table :vouch_recovery_codes, id: :uuid")
    expect(migration).to include("t.uuid")
  end

  it "generates a subject version for verifiable credentials" do
    @generator_directory = run_generator(
      Vouch::Generators::VerifiableGenerator,
      ["phone_verifications"]
    )
    migration = File.read(Dir[File.join(@generator_directory, "db/migrate/*verifiable*.rb")].first)

    expect(migration).to include(":verification_version")
    expect(migration).to include("default: 0, null: false")
  end

  it "reuses an existing account in the generated invitation controller" do
    @generator_directory = run_generator(
      Vouch::Generators::InvitationsGenerator,
      ["users", "Account"]
    )
    controller = File.read(File.join(@generator_directory, "app/controllers/users/invitations_controller.rb"))

    expect(controller).to include("auth_scope :user")
    expect(controller).to include("find_by(\"LOWER(email_address) = ?\", normalized_identifier)")
    expect(controller).to include("email_address: normalized_identifier")
    expect(controller).to include("registration_required: true")
    migration = File.read(Dir[File.join(@generator_directory, "db/migrate/*add_registration_required_to_accounts.rb")].sole)
    expect(migration).to include("add_column :accounts, :registration_required, :boolean, default: false, null: false")
  end
  it "generates registration state on the single-model account table" do
    @generator_directory = run_generator(
      Vouch::Generators::InvitationsGenerator, ["members"], { single_model: true }
    )
    migration = File.read(Dir[File.join(@generator_directory, "db/migrate/*add_registration_required_to_members.rb")].sole)
    expect(migration).to include("add_column :members, :registration_required")
  end

  it "shares one registration-state migration across identity scopes for the same account" do
    @generator_directory = run_generator(Vouch::Generators::InvitationsGenerator, ["users", "Account"])
    generator = Vouch::Generators::InvitationsGenerator.new(["members", "Account"])
    generator.destination_root = @generator_directory
    generator.invoke_all
    expect(Dir[File.join(@generator_directory, "db/migrate/*add_registration_required_to_accounts.rb")].length).to eq(1)
  end

end
