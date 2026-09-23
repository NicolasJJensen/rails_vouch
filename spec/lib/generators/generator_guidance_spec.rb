# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/generators"
require "fileutils"
require "tmpdir"
require "generators/vouch/scope/scope_generator"

RSpec.describe "authentication generator guidance" do
  it "prints host setup steps after generating a scope" do
    directory = Dir.mktmpdir("vouch-guidance")
    FileUtils.mkdir_p(File.join(directory, "config"))
    File.write(File.join(directory, "config/routes.rb"), "Vouch.routes(self) { |auth| }\n")

    output = Dir.chdir(directory) do
      generator = Vouch::Generators::ScopeGenerator.new(
        ["users", "Account:account", "User:identity"]
      )
      generator.destination_root = directory
      capture(:stdout) { generator.invoke_all }
    end

    expect(output).to include("Next steps")
    expect(output).to include("feature guides")
    expect(output).to include("email defaults", "application-specific account validations")
    expect(output).to match(/delivery|resolver|controller/i)
  ensure
    FileUtils.rm_rf(directory)
  end

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
