# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "fileutils"
require "tmpdir"

require "generators/vouch/install/install_generator"
require "generators/vouch/scope/scope_generator"

RSpec.describe "documentation executable contracts" do
  def documentation_ruby_block(path:, containing:)
    blocks = File.read(Rails.root.join("..", "..", path)).scan(/```ruby\n(.*?)```/m).flatten
    block = blocks.find { |candidate| candidate.include?(containing) }
    expect(block).to be_present, "expected a non-empty Ruby example containing #{containing.inspect} in #{path}"
    block
  end

  it "keeps the split-model route sample at the generated baseline" do
    source = documentation_ruby_block(
      path: "README.md",
      containing: 'auth.scope :user, account: "Account"'
    )
    expect(source).to include("Vouch.routes(self)")

    previous_mapping = Vouch.mappings[:user]
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { eval(source, binding, "README.md") } # rubocop:disable Security/Eval

    helpers = routes.url_helpers
    expect(helpers).to respond_to(:new_user_session_path)
    expect(helpers).to respond_to(:new_user_registration_path)
    expect(helpers).to respond_to(:user_select_path)
    expect(helpers).not_to respond_to(:new_user_password_path)
    expect(helpers).not_to respond_to(:new_user_two_factor_credential_path)
  ensure
    if defined?(previous_mapping) && previous_mapping
      Vouch.mappings[:user] = previous_mapping
    else
      Vouch.deregister_mapping(:user) if defined?(Vouch)
    end
  end

  it "executes the verification and MFA Account example without replacing the persisted preference" do
    source = documentation_ruby_block(
      path: "docs/verification-and-mfa.md",
      containing: "class Account < ApplicationRecord"
    )
    expect(source).to include("authenticates_with :two_factorable")
    expect(source).not_to include("def two_factor_enabled?")
    account = create(:account, two_factor_enabled: false)
    credential = account.two_factor_credentials.create!(verified_at: Time.current,
      two_factor_enabled_at: Time.current, enabled: true)

    expect(credential).to be_verified
    expect(credential).to be_two_factor_enabled
    expect(account.reload).not_to be_two_factor_enabled
    account.enable_two_factor!
    expect(account.reload).to be_two_factor_enabled
  end

  it "documents manual route scaffold paste before the scope command" do
    readme = File.read(Rails.root.join("..", "..", "README.md"))
    install = readme.index("vouch:install")
    paste = readme.index("paste", install)
    scope = readme.index("vouch:scope", install)

    expect(install).to be_present
    expect(paste).to be_present
    expect(scope).to be_present
    expect(paste).to be < scope
  end

  it "represents the install output paste before running the scope generator" do
    directory = Dir.mktmpdir("vouch-readme-install")
    FileUtils.mkdir_p(File.join(directory, "config"))
    output = Dir.chdir(directory) do
      generator = Vouch::Generators::InstallGenerator.new([])
      generator.destination_root = directory
      capture(:stdout) { generator.invoke_all }
    end

    output = output.gsub(/\e\[[0-9;]*m/, "")
    scaffold = output[/Vouch\.routes\(self\) do \|auth\|.*?^\s*end/m]
    expect(scaffold).to include("Vouch.routes(self)")
    File.write(File.join(directory, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        #{scaffold}
      end
    RUBY

    Dir.chdir(directory) do
      generator = Vouch::Generators::ScopeGenerator.new(
        ["users", "Account:account", "User:identity"]
      )
      generator.destination_root = directory
      generator.invoke_all
    end

    routes = File.read(File.join(directory, "config/routes.rb"))
    expect(routes).to include('auth.scope :user, account: "Account", identity: "User"')
    expect(routes).to include("auth.sessions")
    expect(routes).to include("auth.registrations")
    expect(routes).to include("auth.user_selection")
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  private

  def capture(stream)
    original = stream == :stdout ? $stdout : $stderr
    captured = StringIO.new
    stream == :stdout ? $stdout = captured : $stderr = captured
    yield
    captured.string
  ensure
    stream == :stdout ? $stdout = original : $stderr = original
  end
end
