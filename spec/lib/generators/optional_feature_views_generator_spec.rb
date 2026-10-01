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

  it "generates password reset UI by default and supports explicit naming" do
    directory = generate(Vouch::Generators::PasswordResetableGenerator, ["Account"])
    expect(File).to exist(File.join(directory, "app/views/accounts/password_resets/new.html.erb"))

    directory = generate(Vouch::Generators::PasswordResetableGenerator, ["Account"],
      auth_scope: "user", controller_path: "users")
    expect(File.read(File.join(directory, "app/controllers/users/password_resets_controller.rb"))).not_to include("auth_scope :user")
    new_view = File.read(File.join(directory, "app/views/users/password_resets/new.html.erb"))
    edit_view = File.read(File.join(directory, "app/views/users/password_resets/edit.html.erb"))
    expect(new_view).to include("form_with url: vouch_route_path(:password_resets, :create), method: :post")
    expect(new_view).to include("email_field_tag :email_address")
    expect(edit_view).to include("form_with url: vouch_route_path(:password_resets, :update), scope: :account, method: :patch")
    expect(edit_view).to include("hidden_field_tag :token, params[:token]")
  end

  it "accepts a single password reset UI route option" do
    directory = Dir.mktmpdir("vouch-optional-view")
    @directories << directory

    expect(Vouch::Generators::PasswordResetableGenerator.new(["Account"], auth_scope: "user")).to be_a(Vouch::Generators::PasswordResetableGenerator)
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
    expect(routes.scan("auth.password_resets").length).to eq(1)
    expect(File).to exist(File.join(directory, "app/mailers/account_password_reset_mailer.rb"))
  end

  it "generates challenge and enrollment UI for MFA" do
    directory = generate(Vouch::Generators::TwoFactorableGenerator, ["Totp"],
      auth_scope: "user", controller_path: "users")
    expect(File.read(File.join(directory, "app/controllers/users/two_factor_challenge_controller.rb"))).not_to include("auth_scope :user")
    expect(File).to exist(File.join(directory, "app/controllers/users/two_factor_credentials_controller.rb"))
    index = File.read(File.join(directory, "app/views/users/two_factor_challenge/index.html.erb"))
    challenge = File.read(File.join(directory, "app/views/users/two_factor_challenge/show.html.erb"))
    expect(index).to include('credential_param = "#{credential.model_name.singular}-#{Vouch::RecordKey.to_param(credential)}"')
    expect(index).to include("vouch_route_path(:two_factor_challenges, :show, id: credential_param)")
    expect(challenge).to include('credential_param = "#{@credential.model_name.singular}-#{Vouch::RecordKey.to_param(@credential)}"')
    expect(challenge).to include("vouch_route_path(:two_factor_challenges, :update, id: credential_param), method: :patch")
    expect(challenge).to include("vouch_route_path(:two_factor_challenges, :send_code, id: credential_param), method: :post")
    expect(challenge).not_to include('inputmode: "numeric"')
    expect(File).to exist(File.join(directory, "app/views/users/two_factor_credentials/new.html.erb"))
    expect(File).not_to exist(File.join(directory, "app/controllers/users/recovery_codes_controller.rb"))
  end

  it "adds independent MFA declarations once and preserves custom declarations" do
    directory = Dir.mktmpdir("vouch-mfa-routes")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    FileUtils.mkdir_p(File.join(directory, "config"))
    File.write(File.join(directory, "app/models/user.rb"), "class User < ApplicationRecord\nend\n")
    File.write(File.join(directory, "app/models/phone.rb"), "class Phone < ApplicationRecord\n  belongs_to :user\nend\n")
    File.write(File.join(directory, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope model: "User" do
            auth.two_factor_challenges controller: "custom/challenges", path_names: {index: :challenge_choices}
          end
        end
      end
    RUBY

    2.times do
      generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], subject: ["e164"])
      generator.destination_root = directory
      Dir.chdir(directory) { generator.invoke_all }
    end

    routes = File.read(File.join(directory, "config/routes.rb"))
    expect(routes.scan("auth.two_factor_challenges").size).to eq(1)
    expect(routes).to include('auth.two_factor_challenges controller: "custom/challenges", path_names: {index: :challenge_choices}')
    expect(routes.scan('auth.two_factor_credentials controller: "users/two_factor_credentials"').size).to eq(1)
    expect(routes).not_to include("auth.recovery_codes")
  end

  it "accepts a controller path without an explicit route scope" do
    directory = Dir.mktmpdir("vouch-optional-view")
    @directories << directory

    expect(Vouch::Generators::TwoFactorableGenerator.new(["Totp"], controller_path: "users")).to be_a(Vouch::Generators::TwoFactorableGenerator)
  end

  it "wires a credential model separately from its owning account" do
    directory = Dir.mktmpdir("vouch-two-factor-credential")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(File.join(directory, "app/models/phone.rb"), <<~RUBY)
      class Phone < ApplicationRecord
        belongs_to :user
      end
    RUBY
    File.write(File.join(directory, "app/models/user.rb"), "class User < ApplicationRecord\nend\n")

    generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], subject: ["e164"])
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }

    phone = File.read(File.join(directory, "app/models/phone.rb"))
    user = File.read(File.join(directory, "app/models/user.rb"))
    expect(phone).to include("include Vouch::Verifiable")
    expect(phone).to include("include Vouch::TwoFactorable")
    expect(phone).to include("authentication_owner :user")
    expect(phone).to include("self.verifiable_subject_attribute = :e164")
    expect(phone).to include("def deliver_verification_code")
    expect(phone).to include("def deliver_two_factor_code")
    expect(phone).not_to include("authenticates_with :two_factorable")
    expect(user).to include("authenticates_with :two_factorable")
    expect(user).to include("has_many :phones")
    expect(Dir[File.join(directory, "db/migrate/*two_factor_enabled*users*.rb")]).not_to be_empty
  end

  it "infers a multiline class_name owner and keeps an explicit owner override" do
    directory = Dir.mktmpdir("vouch-two-factor-multiline-owner")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(File.join(directory, "app/models/phone.rb"), <<~RUBY)
      class Phone < ApplicationRecord
        belongs_to :holder,
          class_name: "Account"
      end
    RUBY
    File.write(File.join(directory, "app/models/account.rb"), "class Account < ApplicationRecord\nend\n")

    generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], subject: ["e164"])
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }

    expect(File.read(File.join(directory, "app/models/account.rb"))).to include("has_many :phones")
    expect(File.read(File.join(directory, "app/models/phone.rb"))).to include("authentication_owner :holder")
    expect(File.read(File.join(directory, "app/models/account.rb"))).to include("foreign_key: :holder_id")

    explicit = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], owner: "Account")
    explicit.destination_root = directory
    expect { Dir.chdir(directory) { explicit.invoke_all } }.not_to raise_error
  end

  it "wires the selected owner association when another belongs_to exists" do
    directory = Dir.mktmpdir("vouch-two-factor-selected-owner")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(File.join(directory, "app/models/phone.rb"), <<~RUBY)
      class Phone < ApplicationRecord
        belongs_to :account
        belongs_to :organisation
      end
    RUBY
    File.write(File.join(directory, "app/models/account.rb"), "class Account < ApplicationRecord\nend\n")
    generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], owner: "Account", model_only: true)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
    expect(File.read(File.join(directory, "app/models/phone.rb"))).to include("authentication_owner :account")
  end

  it "preserves custom owner keys in the generated inverse association" do
    directory = Dir.mktmpdir("vouch-two-factor-owner-keys")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(File.join(directory, "app/models/phone.rb"), <<~RUBY)
      class Phone < ApplicationRecord
        belongs_to :holder, class_name: "Account", foreign_key: [:realm, :owner_key], primary_key: [:realm, :key]
      end
    RUBY
    File.write(File.join(directory, "app/models/account.rb"), "class Account < ApplicationRecord\nend\n")
    generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], owner: "Account", model_only: true)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
    expect(File.read(File.join(directory, "app/models/account.rb")))
      .to include("foreign_key: [:realm, :owner_key], primary_key: [:realm, :key]")
  end

  it "rejects an owner with no matching association before generating a migration" do
    directory = Dir.mktmpdir("vouch-two-factor-wrong-owner")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(File.join(directory, "app/models/phone.rb"), "class Phone < ApplicationRecord\n  belongs_to :user\nend\n")
    generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], owner: "Account", model_only: true)
    generator.destination_root = directory
    expect { Dir.chdir(directory) { generator.invoke_all } }.to raise_error(Thor::Error, /belongs_to association/)
    expect(Dir[File.join(directory, "db/migrate/*")]).to be_empty
  end

  it "rejects a missing declared owner instead of treating the credential as its own owner" do
    directory = Dir.mktmpdir("vouch-two-factor-missing-declaration")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(File.join(directory, "app/models/phone.rb"), "class Phone < ApplicationRecord\n  belongs_to :user\n  authentication_owner :missing\nend\n")
    generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"], model_only: true)
    generator.destination_root = directory
    expect { Dir.chdir(directory) { generator.invoke_all } }.to raise_error(Thor::Error, /must name an existing belongs_to/)
    expect(Dir[File.join(directory, "db/migrate/*")]).to be_empty
  end

  it "names the actual credential class in the inverse association" do
    directory = Dir.mktmpdir("vouch-two-factor-namespaced-credential")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models/contacts"))
    File.write(File.join(directory, "app/models/contacts/phone.rb"), "class Contacts::Phone < ApplicationRecord\n  belongs_to :account\nend\n")
    File.write(File.join(directory, "app/models/account.rb"), "class Account < ApplicationRecord\nend\n")
    generator = Vouch::Generators::TwoFactorableGenerator.new(["Contacts::Phone"], owner: "::Account", model_only: true)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
    expect(File.read(File.join(directory, "app/models/account.rb"))).to include('class_name: "Contacts::Phone"')
  end

  it "adds an invitation view beside the existing invitation controller" do
    directory = generate(Vouch::Generators::InvitationsGenerator, ["User", "Account"],
      auth_scope: "user", controller_path: "users")
    controller = File.read(File.join(directory, "app/controllers/users/invitations_controller.rb"))
    view = File.read(File.join(directory, "app/views/users/invitations/new.html.erb"))
    expect(controller).to include("Account.find_by")
    expect(view).to include("form_with url: vouch_route_path(:invitations, :create), method: :post")
    expect(view).to include("email_field_tag :email_address")
  end

  it "adds the required invitation controller for a single-model scope" do
    directory = generate(Vouch::Generators::InvitationsGenerator, ["members"],
      single_model: true, auth_scope: "member", controller_path: "members")

    controller = File.read(File.join(directory, "app/controllers/members/invitations_controller.rb"))
    expect(controller).to include("class Members::InvitationsController < Vouch::InvitationsController")
    expect(controller).not_to include("auth_scope :member")
    expect(controller).to include("Member.find_by")
    expect(controller).to include("def create", "def resend", "Authorize @invitation")
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

    expect(File).to exist(File.join(password_directory, "app/views/#{view_path}/password_resets/new.html.erb"))
    expect(File).to exist(File.join(two_factor_directory, "app/views/#{view_path}/two_factor_challenge/show.html.erb"))
    expect(File).to exist(File.join(invitation_directory, "app/views/#{view_path}/invitations/new.html.erb"))
  end
end
