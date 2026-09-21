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

  describe "non-concrete eject" do
    it "copies the controller verbatim with the class declaration rewritten" do
      run_generator(["users", "sessions"], {})

      body = written("app/controllers/users/sessions_controller.rb")
      expect(body).to include("class Users::SessionsController < Vouch::BaseController")
      expect(body).not_to include("class Vouch::SessionsController")
    end

    it "preserves auth_mapping references" do
      run_generator(["users", "passwords"], {})

      body = written("app/controllers/users/passwords_controller.rb")
      expect(body).to include("auth_mapping.account_class")
      expect(body).to include("auth_mapping.account_param_key")
    end

    it "adds an explicit runtime scope when the output namespace differs" do
      run_generator(["portal", "sessions"], auth_scope: "user")

      body = written("app/controllers/portal/sessions_controller.rb")
      expect(body).to include("class Portal::SessionsController < Vouch::BaseController")
      expect(body).to include("  auth_scope :user")

      stub_const("Portal", Module.new)
      eval(body, TOPLEVEL_BINDING, "portal/sessions_controller.rb")
      expect(Portal::SessionsController.allocate.send(:auth_mapping)).to eq(
        Vouch.mapping_for(:user)
      )
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

  describe "--concrete compatibility alias" do
    it "warns and emits the same compilable controller as normal ejection" do
      normal_dir = Dir.mktmpdir("eject-normal")
      concrete_dir = Dir.mktmpdir("eject-concrete")
      normal_output = run_generator_at(normal_dir, ["users", "sessions"])
      concrete_output = run_generator_at(concrete_dir, ["users", "sessions"], concrete: true)
      normal_body = File.read(File.join(normal_dir, "app/controllers/users/sessions_controller.rb"))
      concrete_body = File.read(File.join(concrete_dir, "app/controllers/users/sessions_controller.rb"))

      expect(concrete_output).to match(/deprecated|compatibility/i)
      expect(concrete_output).to match(/runtime helpers|auth_mapping/i)
      expect(concrete_body).to eq(normal_body)
      expect { RubyVM::InstructionSequence.compile(concrete_body) }.not_to raise_error
    ensure
      FileUtils.rm_rf(normal_dir)
      FileUtils.rm_rf(concrete_dir)
    end

    it "does not require a registered mapping" do
      saved = Vouch.mappings.dup
      Vouch.mappings.clear

      output = run_generator(["ghosts", "sessions"], concrete: true)
      body = written("app/controllers/ghosts/sessions_controller.rb")

      expect(output).to match(/deprecated|compatibility/i)
      expect(body).to include("class Ghosts::SessionsController")
      expect { RubyVM::InstructionSequence.compile(body) }.not_to raise_error
    ensure
      Vouch.mappings.replace(saved)
    end

    it "preserves an explicitly selected runtime scope" do
      normal_dir = Dir.mktmpdir("eject-normal-scope")
      concrete_dir = Dir.mktmpdir("eject-concrete-scope")
      run_generator_at(normal_dir, ["portal", "sessions"], auth_scope: "user")
      output = run_generator_at(concrete_dir, ["portal", "sessions"],
                                concrete: true, auth_scope: "user")

      normal_body = File.read(File.join(normal_dir, "app/controllers/portal/sessions_controller.rb"))
      concrete_body = File.read(File.join(concrete_dir, "app/controllers/portal/sessions_controller.rb"))

      expect(output).to match(/deprecated|compatibility/i)
      expect(concrete_body).to eq(normal_body)
      expect(concrete_body).to include("auth_scope :user")
    ensure
      FileUtils.rm_rf(normal_dir)
      FileUtils.rm_rf(concrete_dir)
    end
  end
end
