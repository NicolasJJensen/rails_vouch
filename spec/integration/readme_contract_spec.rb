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
      containing: 'auth.scope :account, model: "Account"'
    )
    expect(source).to include("Vouch.routes(self)")

    previous_mappings = Vouch.mappings.dup
    serializers = Warden::SessionSerializer.instance_methods(false).to_h do |name|
      [name, Warden::SessionSerializer.instance_method(name)]
    end
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { eval(source, binding, "README.md") } # rubocop:disable Security/Eval

    helpers = routes.url_helpers
    expect(helpers).to respond_to(:new_user_session_path)
    expect(helpers).to respond_to(:new_account_registration_path)
    expect(helpers).to respond_to(:new_account_session_path)
    expect(helpers).not_to respond_to(:user_select_path)
    expect(helpers).not_to respond_to(:new_user_password_reset_path)
    expect(helpers).not_to respond_to(:new_user_two_factor_credential_path)
  ensure
    if defined?(previous_mappings) && previous_mappings
      Vouch.mappings.replace(previous_mappings)
      Vouch::ApplicationHelpers.refresh!
      Vouch.configured_warden_configs.each { |config| Vouch.configure_warden(config) }
    end
    if serializers
      (Warden::SessionSerializer.instance_methods(false) - serializers.keys).each do |name|
        Warden::SessionSerializer.send(:remove_method, name)
      end
      serializers.each { |name, method| Warden::SessionSerializer.send(:define_method, name, method) }
    end
  end

  it "documents attribute-bound verification without replacing the persisted MFA preference" do
    source = documentation_ruby_block(
      path: "docs/verification-and-mfa.md",
      containing: "self.verifiable_subject_attribute = :e164"
    )
    expect(source).to include("self.verifiable_subject_attribute = :e164")
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

  it "installs the documented single-model setup without manual route edits" do
    directory = Dir.mktmpdir("vouch-readme-install")
    FileUtils.mkdir_p(File.join(directory, "config"))
    File.write(File.join(directory, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        root "dashboard#show"
      end
    RUBY

    Dir.chdir(directory) do
      installer = Vouch::Generators::InstallGenerator.new([])
      installer.destination_root = directory
      installer.invoke_all
      generator = Vouch::Generators::ScopeGenerator.new(["users", "User"], single_model: true)
      generator.destination_root = directory
      generator.invoke_all
    end

    routes = File.read(File.join(directory, "config/routes.rb"))
    expect(routes.scan("Vouch.routes(self)").size).to eq(1)
    expect(routes).to include('auth.scope :user, model: "User"')
    expect(routes).to include('root "dashboard#show"', "auth.sessions", "auth.registrations")
    expect(routes).not_to include("auth.user_selection")
    model = File.read(File.join(directory, "app/models/user.rb"))
    expect(model).to include("normalizes :email_address", "uniqueness: { case_sensitive: false }")
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
