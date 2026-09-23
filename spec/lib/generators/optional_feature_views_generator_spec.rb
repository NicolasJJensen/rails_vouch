# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/generators"
require "fileutils"
require "tmpdir"

require "generators/vouch/password_resetable/password_resetable_generator"
require "generators/vouch/two_factorable/two_factorable_generator"
require "generators/vouch/invitations/invitations_generator"

RSpec.describe "optional feature view generators" do
  def generate(generator_class, args, options = {})
    directory = Dir.mktmpdir("vouch-optional-view")
    @directories << directory
    generator = generator_class.new(args, options)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
    directory
  end

  before { @directories = [] }
  after { @directories.each { |directory| FileUtils.rm_rf(directory) } }

  it "keeps password reset model-only unless an auth scope and controller path are supplied" do
    directory = generate(Vouch::Generators::PasswordResetableGenerator, ["Account"])
    expect(File).not_to exist(File.join(directory, "app/views/accounts/passwords/new.html.erb"))

    directory = generate(Vouch::Generators::PasswordResetableGenerator, ["Account"],
      auth_scope: "user", controller_path: "users")
    expect(File.read(File.join(directory, "app/controllers/users/passwords_controller.rb"))).to include("auth_scope :user")
    new_view = File.read(File.join(directory, "app/views/users/passwords/new.html.erb"))
    edit_view = File.read(File.join(directory, "app/views/users/passwords/edit.html.erb"))
    expect(new_view).to include("form_with url: user_password_path, method: :post")
    expect(new_view).to include("email_field_tag :email_address")
    expect(edit_view).to include("form_with url: user_password_path, scope: :account, method: :patch")
    expect(edit_view).to include("hidden_field_tag :token, params[:token]")
  end

  it "requires both route options before generating password reset UI" do
    directory = Dir.mktmpdir("vouch-optional-view")
    @directories << directory

    expect {
      Vouch::Generators::PasswordResetableGenerator.new(["Account"], auth_scope: "user")
    }.to raise_error(Thor::Error, /--auth-scope and --controller-path together/)
    expect(Dir[File.join(directory, "db/migrate/*.rb")]).to be_empty
  end

  it "wires password reset authentication, delivery, and account routes idempotently" do
    directory = Dir.mktmpdir("vouch-password-reset")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    FileUtils.mkdir_p(File.join(directory, "config"))
    File.write(File.join(directory, "app/models/account.rb"), "class Account < ApplicationRecord\n  include Vouch::Authenticatable\nend\n")
    File.write(File.join(directory, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :account, model: "Account" do
            auth.sessions
            auth.registrations
          end
        end
      end
    RUBY

    2.times do
      generator = Vouch::Generators::PasswordResetableGenerator.new(
        ["Account"], auth_scope: "account", controller_path: "accounts"
      )
      generator.destination_root = directory
      Dir.chdir(directory) { generator.invoke_all }
    end

    model = File.read(File.join(directory, "app/models/account.rb"))
    routes = File.read(File.join(directory, "config/routes.rb"))
    expect(model.scan("authenticates_with :password_resetable").length).to eq(1)
    expect(model).to include("AccountPasswordResetMailer.reset")
    expect(routes.scan("auth.passwords").length).to eq(1)
    expect(File).to exist(File.join(directory, "app/mailers/account_password_reset_mailer.rb"))
  end

  it "generates only challenge UI for MFA with an explicit authentication scope" do
    directory = generate(Vouch::Generators::TwoFactorableGenerator, ["Totp"],
      auth_scope: "user", controller_path: "users")
    expect(File.read(File.join(directory, "app/controllers/users/two_factor_challenge_controller.rb"))).to include("auth_scope :user")
    expect(File).not_to exist(File.join(directory, "app/controllers/users/two_factor_credentials_controller.rb"))
    index = File.read(File.join(directory, "app/views/users/two_factor_challenge/index.html.erb"))
    challenge = File.read(File.join(directory, "app/views/users/two_factor_challenge/show.html.erb"))
    expect(index).to include('credential_param = "#{credential.model_name.singular}-#{credential.to_param}"')
    expect(index).to include("user_two_factor_challenge_path(credential_param)")
    expect(challenge).to include('credential_param = "#{@credential.model_name.singular}-#{@credential.to_param}"')
    expect(challenge).to include("user_two_factor_challenge_path(credential_param), method: :patch")
    expect(challenge).to include("send_code_user_two_factor_challenge_path(credential_param), method: :post")
    expect(challenge).not_to include('inputmode: "numeric"')
    expect(File).not_to exist(File.join(directory, "app/views/users/two_factor_credentials/new.html.erb"))
  end

  it "requires both route options before generating two-factor UI" do
    directory = Dir.mktmpdir("vouch-optional-view")
    @directories << directory

    expect {
      Vouch::Generators::TwoFactorableGenerator.new(["Totp"], controller_path: "users")
    }.to raise_error(Thor::Error, /--auth-scope and --controller-path together/)
    expect(Dir[File.join(directory, "db/migrate/*.rb")]).to be_empty
  end

  it "adds an invitation view beside the existing invitation controller" do
    directory = generate(Vouch::Generators::InvitationsGenerator, ["User", "Account"],
      auth_scope: "user", controller_path: "users")
    controller = File.read(File.join(directory, "app/controllers/users/invitations_controller.rb"))
    view = File.read(File.join(directory, "app/views/users/invitations/new.html.erb"))
    expect(controller).to include("Account.find_by")
    expect(view).to include("form_with url: user_invitation_path, method: :post")
    expect(view).to include("email_field_tag :email_address")
  end

  it "adds the required invitation controller for a single-model scope" do
    directory = generate(Vouch::Generators::InvitationsGenerator, ["members"],
      single_model: true, auth_scope: "member", controller_path: "members")

    controller = File.read(File.join(directory, "app/controllers/members/invitations_controller.rb"))
    expect(controller).to include("class Members::InvitationsController < Vouch::InvitationsController")
    expect(controller).to include("auth_scope :member")
    expect(controller).to include("Member.find_by")
    expect(controller).to include("raise Vouch::ConfigurationError")
  end

  it "uses the invitation controller's conventional namespace when options are omitted" do
    directory = generate(Vouch::Generators::InvitationsGenerator, ["Admin::Phone", "Account"])

    expect(File).to exist(File.join(directory, "app/controllers/admin/phones/invitations_controller.rb"))
    expect(File).to exist(File.join(directory, "app/views/admin/phones/invitations/new.html.erb"))
  end

  it "uses Rails' normalized view path for controller namespaces containing digits" do
    controller_path = "admin/generated_members_6786369961s"
    view_path = "admin/generated_members6786369961s"

    password_directory = generate(Vouch::Generators::PasswordResetableGenerator, ["Account"],
      auth_scope: "user", controller_path: controller_path)
    two_factor_directory = generate(Vouch::Generators::TwoFactorableGenerator, ["Totp"],
      auth_scope: "user", controller_path: controller_path)
    invitation_directory = generate(Vouch::Generators::InvitationsGenerator, ["User", "Account"],
      auth_scope: "user", controller_path: controller_path)

    expect(File).to exist(File.join(password_directory, "app/views/#{view_path}/passwords/new.html.erb"))
    expect(File).to exist(File.join(two_factor_directory, "app/views/#{view_path}/two_factor_challenge/show.html.erb"))
    expect(File).to exist(File.join(invitation_directory, "app/views/#{view_path}/invitations/new.html.erb"))
  end
end
