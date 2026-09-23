# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require "generators/vouch/eject/eject_generator"

RSpec.describe Vouch::Generators::EjectGenerator do
  let(:tmpdir) { Dir.mktmpdir("eject-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  def run_generator(args, options = {})
    run_generator_at(tmpdir, args, options)
  end

  def run_generator_at(directory, args, options = {})
    Dir.chdir(directory) do
      gen = described_class.new(args, options)
      capture(:stdout) { gen.invoke_all }
    end
  end

  # Tiny silence helper so generator chatter doesn't pollute the spec output.
  def capture(stream)
    original = $stdout if stream == :stdout
    original = $stderr if stream == :stderr
    captured = StringIO.new
    $stdout = captured if stream == :stdout
    $stderr = captured if stream == :stderr
    yield
    captured.string
  ensure
    $stdout = original if stream == :stdout
    $stderr = original if stream == :stderr
  end

  def written(path)
    File.read(File.join(tmpdir, path))
  end

  describe "eject" do
    it "copies the controller verbatim with the class declaration rewritten" do
      run_generator(["users", "sessions"], {})

      body = written("app/controllers/users/sessions_controller.rb")
      expect(body).to include("class Users::SessionsController < ::ApplicationController")
      expect(body).not_to include("class Vouch::SessionsController")
    end

    it "preserves auth_mapping references" do
      run_generator(["users", "password_resets"], {})

      body = written("app/controllers/users/password_resets_controller.rb")
      expect(body).to include("auth_mapping.account_class")
      expect(body).to include("auth_mapping.account_param_key")
    end

    it "adds an explicit runtime scope when the output namespace differs" do
      run_generator(["portal", "sessions"], auth_scope: "user")

      body = written("app/controllers/portal/sessions_controller.rb")
      expect(body).to include("class Portal::SessionsController < ::ApplicationController")
      expect(body).to match(/include Vouch::Authentication\n  auth_scope :user/)

      expect { RubyVM::InstructionSequence.compile(body) }.not_to raise_error
    end

    it "keeps runtime scope inference when no explicit scope is supplied" do
      run_generator(["users", "sessions"])

      body = written("app/controllers/users/sessions_controller.rb")
      expect(body).not_to include("auth_scope :")
    end

    it "raises Thor::Error for unknown controller names" do
      expect {
        run_generator(["users", "bogus"], {})
      }.to raise_error(Thor::Error, /Unknown controller 'bogus'/)
    end
  end

end
