# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require "generators/vouch/eject/eject_generator"
require "generators/vouch/two_factorable/two_factorable_generator"

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

  describe "generic verification ejection" do
    %w[verifications temporary_verifications].each do |endpoint|
      it "copies #{endpoint} without an authentication scope" do
        run_generator(["contacts", endpoint])
        source = written("app/controllers/contacts/#{endpoint}_controller.rb")
        expect(source).not_to include("auth_scope")
        expect(written("app/controllers/contacts/#{endpoint}_implementation_controller.rb")).to include("def create")
      end
    end
  end

  describe "eject" do
    it "copies the controller verbatim with the class declaration rewritten" do
      run_generator(["users", "sessions"], {})

      body = written("app/controllers/users/sessions_implementation_controller.rb")
      host = written("app/controllers/users/sessions_controller.rb")
      expect(body).to include("class Users::SessionsImplementationController < ::ApplicationController")
      expect(host).to include("class Users::SessionsController < Users::SessionsImplementationController")
      expect(body).not_to include("class Vouch::SessionsController")
    end

    it "preserves auth_mapping references" do
      run_generator(["users", "password_resets"], {})

      body = written("app/controllers/users/password_resets_implementation_controller.rb")
      expect(body).to include("auth_mapping.account_class")
      expect(body).to include("auth_mapping.account_param_key")
    end

    it "adds an explicit runtime scope when the output namespace differs" do
      run_generator(["portal", "sessions"], auth_scope: "user")

      body = written("app/controllers/portal/sessions_controller.rb")
      expect(body).to include("class Portal::SessionsController < Portal::SessionsImplementationController")
      expect(body).to include("auth_scope :user")

      expect { RubyVM::InstructionSequence.compile(body) }.not_to raise_error
    end

    it "keeps runtime scope inference when no explicit scope is supplied" do
      run_generator(["users", "sessions"])

      body = written("app/controllers/users/sessions_controller.rb")
      expect(body).not_to include("auth_scope :")
    end

    it "rejects unsupported host syntax before creating or changing any files" do
      directory = File.join(tmpdir, "app/controllers/users")
      FileUtils.mkdir_p(directory)
      target = File.join(directory, "sessions_controller.rb")
      original = "module Users\n  class SessionsController < Vouch::SessionsController\n  end\nend\n"
      File.write(target, original)

      expect { run_generator(["users", "sessions"]) }
        .to raise_error(Thor::Error, /nested module syntax/)
      expect(File.read(target)).to eq(original)
      expect(Dir.children(directory)).to eq(["sessions_controller.rb"])
    end

    it "raises Thor::Error for unknown controller names" do
      expect {
        run_generator(["users", "bogus"], {})
      }.to raise_error(Thor::Error, /Unknown controller 'bogus'/)
    end

    it "executes an existing override through super and preserves local action edits on reruns" do
      stub_const("EjectedMembers", Module.new)
      directory = File.join(tmpdir, "app/controllers/ejected_members")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "sessions_controller.rb"), <<~RUBY)
        class EjectedMembers::SessionsController < Vouch::SessionsController
          def new
            @host_result = super
          end
          attr_reader :host_result
        end
      RUBY
      run_generator(["ejected_members", "sessions"], auth_scope: "user")
      implementation = File.join(directory, "sessions_implementation_controller.rb")
      File.write(implementation, File.read(implementation).sub("def new; end", "def new; :local_action; end"))
      run_generator(["ejected_members", "sessions"], auth_scope: "user")

      load implementation
      load File.join(directory, "sessions_controller.rb")
      controller = EjectedMembers::SessionsController.new
      controller.new

      expect(controller.host_result).to eq(:local_action)
      expect(controller.class.ancestors).not_to include(Vouch::SessionsController)
    end

    it "retains generated enrollment and grouped management after ejection" do
      stub_const("EjectedOwners", Module.new)
      Dir.chdir(tmpdir) do
        generator = Vouch::Generators::TwoFactorableGenerator.new(["Phone"],
          owner: "Account", auth_scope: "user", controller_path: "ejected_owners", subject: ["e164"])
        capture(:stdout) { generator.invoke(:create_optional_ui) }
      end
      run_generator(["ejected_owners", "two_factor_credentials"], auth_scope: "user")
      directory = File.join(tmpdir, "app/controllers/ejected_owners")
      load File.join(directory, "two_factor_credentials_implementation_controller.rb")
      load File.join(directory, "two_factor_credentials_controller.rb")
      controller = EjectedOwners::TwoFactorCredentialsController.new
      credential = Object.new
      relation = double("phones", new: credential)
      allow(controller).to receive(:credential_relation).and_return(relation)

      expect(controller.class._process_action_callbacks.map(&:filter)).to include(:build_credential)
      controller.send(:build_credential)
      controller.new
      expect(controller.instance_variable_get(:@credential)).to equal(credential)
      expect(controller.method(:update).owner).to eq(EjectedOwners::TwoFactorCredentialsController)

      account = double("account", two_factor_credentials: relation)
      allow(controller).to receive(:current_account).and_return(account)
      controller.index
      expect(controller.instance_variable_get(:@credentials_by_kind)).to eq(two_factor_credentials: relation)
      expect(controller.method(:destroy).owner).to eq(EjectedOwners::TwoFactorCredentialsImplementationController)
    end
  end

end
