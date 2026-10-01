require "rails_helper"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "generators/vouch/omniauth/omniauth_generator"

RSpec.describe "OAuth initializer generation" do
  around do |example|
    Dir.mktmpdir("vouch-provider-initializer") do |directory|
      @directory = directory
      example.run
    end
  end

  {"8.1.3" => "Rails.application.credentials.dig", "8.2.0" => "Rails.app.creds.require"}.each do |version, reader|
    it "uses the supported credentials API on Rails #{version}" do
      stub_const("Rails::VERSION::STRING", version)
      generator = Vouch::Generators::OmniauthGenerator.new(["Account"], {provider: "github"}, destination_root: @directory)
      generator.invoke(:create_provider_initializer)
      contents = File.read(File.join(@directory, "config/initializers/vouch_omniauth_github.rb"))
      expect(contents).to include("#{reader}(:github, :client_id)", "#{reader}(:github, :client_secret)")
      expect(Ripper.sexp(contents)).not_to be_nil
    end
  end
end
