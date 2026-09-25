# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/generators"
require "fileutils"
require "tmpdir"
require "generators/vouch/recovery_codes/recovery_codes_generator"

RSpec.describe Vouch::Generators::RecoveryCodesGenerator do
  let(:directory) { Dir.mktmpdir("vouch-recovery-codes") }

  after { FileUtils.rm_rf(directory) }

  def write(path, contents)
    full_path = File.join(directory, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end

  def generate(*arguments, **options)
    generator = described_class.new(arguments, options)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
  end

  it "adds missing account recovery UI using the selected scope and controller path" do
    write "config/routes.rb", <<~RUBY
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :account, model: "Account", path: "portal/accounts" do
            auth.two_factor
          end
        end
      end
    RUBY

    generate "Account", auth_scope: "account", controller_path: "portal/accounts"

    expect(File).to exist(File.join(directory, "app/controllers/portal/accounts/recovery_codes_controller.rb"))
    expect(File.read(File.join(directory, "app/controllers/portal/accounts/recovery_codes_controller.rb"))).to include("Portal::Accounts::RecoveryCodesController")
    view = File.read(File.join(directory, "app/views/portal/accounts/recovery_codes/show.html.erb"))
    expect(view).to include("account_recovery_codes_path")
  end

  it "adds credential-owned recovery UI to the credential owner's custom scope" do
    write "app/models/phone.rb", <<~RUBY
      class Phone < ApplicationRecord
        belongs_to :user
      end
    RUBY
    write "app/models/user.rb", "class User < ApplicationRecord\nend\n"
    write "config/routes.rb", <<~RUBY
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :user, model: "User", path: "portal/users", as: :member do
            auth.two_factor
          end
        end
      end
    RUBY

    generate "Phone", owner: "User"

    expect(File).to exist(File.join(directory, "app/controllers/portal/users/recovery_codes_controller.rb"))
    view = File.read(File.join(directory, "app/views/portal/users/two_factor_challenge/recovery.html.erb"))
    expect(view).to include("member_consume_recovery_two_factor_challenge_path")
  end
end
