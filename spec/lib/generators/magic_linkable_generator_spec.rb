# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/vouch/magic_linkable/magic_linkable_generator"

RSpec.describe Vouch::Generators::MagicLinkableGenerator do
  let(:tmpdir) { Dir.mktmpdir("magic-linkable-gen-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  def run_configure(args, options = {})
    Dir.chdir(tmpdir) do
      gen = described_class.new(args, options)
      gen.destination_root = tmpdir
      capture(:stdout) { gen.configure_model }
    end
  end
  alias_method :run_generator, :run_configure

  def capture(stream)
    original = $stdout
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
    it "injects include Vouch::MagicLinkable into the target model" do
      write_model("app/models/phone.rb", "class Phone < ApplicationRecord\nend\n")

      run_generator(["phones"])

      body = read("app/models/phone.rb")
      expect(body).to include("include Vouch::MagicLinkable")
      expect(body).to include("deliver_sign_in_code")
    end

    it "is idempotent" do
      write_model("app/models/phone.rb", "class Phone < ApplicationRecord\nend\n")

      run_generator(["phones"])
      run_generator(["phones"])

      matches = read("app/models/phone.rb").scan(/include Vouch::MagicLinkable/)
      expect(matches.size).to eq(1)
    end

    it "prints a snippet when the model file is missing" do
      output = run_generator(["phones"])
      expect(output).to match(/Add to app\/models\/phone\.rb/)
      expect(output).to match(/include Vouch::MagicLinkable/)
    end
  end
end
