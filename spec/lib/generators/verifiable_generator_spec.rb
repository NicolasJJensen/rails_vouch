# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/vouch/verifiable/verifiable_generator"

RSpec.describe Vouch::Generators::VerifiableGenerator do
  let(:tmpdir) { Dir.mktmpdir("verifiable-gen-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  # Only exercise the configure_model step here — the migration step is
  # standard Rails::Generators::Migration#migration_template and is covered
  # implicitly via the other feature generators.
  def run_configure(args, options = {})
    Dir.chdir(tmpdir) do
      gen = described_class.new(args, options)
      gen.destination_root = tmpdir
      capture(:stdout) { gen.configure_model }
    end
  end
  alias_method :run_generator, :run_configure

  def capture(stream)
    original = $stdout if stream == :stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  def write_model(path, body)
    full = File.join(tmpdir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  def read(path)
    File.read(File.join(tmpdir, path))
  end

  describe "#configure_model" do
    it "injects include Vouch::Verifiable into the target model" do
      write_model("app/models/email.rb", <<~RUBY)
        class Email < ApplicationRecord
        end
      RUBY

      run_generator(["emails"])

      expect(read("app/models/email.rb")).to include("include Vouch::Verifiable")
      expect(read("app/models/email.rb")).to include("verifiable_subject_attribute")
    end

    it "is idempotent — a second run does not duplicate the include" do
      write_model("app/models/email.rb", <<~RUBY)
        class Email < ApplicationRecord
        end
      RUBY

      run_generator(["emails"])
      run_generator(["emails"])

      matches = read("app/models/email.rb").scan(/include Vouch::Verifiable/)
      expect(matches.size).to eq(1)
    end

    it "prints a snippet when the model file is missing" do
      output = run_generator(["emails"])
      expect(output).to match(/Add to app\/models\/email\.rb/)
      expect(output).to match(/include Vouch::Verifiable/)
    end
  end
end
