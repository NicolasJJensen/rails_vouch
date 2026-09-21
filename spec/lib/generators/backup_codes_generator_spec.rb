# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/vouch/backup_codes/backup_codes_generator"

RSpec.describe Vouch::Generators::BackupCodesGenerator do
  let(:tmpdir) { Dir.mktmpdir("backup-codes-gen-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  def run_configure(args, options = {})
    Dir.chdir(tmpdir) do
      gen = described_class.new(args, options)
      gen.destination_root = tmpdir
      capture(:stdout) { gen.configure_parent_model }
    end
  end
  alias_method :run_generator, :run_configure

  def run_full(args, options = {})
    Dir.chdir(tmpdir) do
      gen = described_class.new(args, options)
      gen.destination_root = tmpdir
      capture(:stdout) { gen.invoke_all }
    end
  end

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

  describe "#configure_parent_model" do
    it "injects concern and has_many into the parent" do
      write_model("app/models/totp.rb", "class Totp < ApplicationRecord\nend\n")

      run_generator(["totps"])

      body = read("app/models/totp.rb")
      expect(body).to include("include Vouch::BackupCodable")
      expect(body).to include(%(has_many :backup_codes, class_name: "TotpBackupCode"))
    end

    it "is idempotent" do
      write_model("app/models/totp.rb", "class Totp < ApplicationRecord\nend\n")

      run_generator(["totps"])
      run_generator(["totps"])

      matches = read("app/models/totp.rb").scan(/include Vouch::BackupCodable/)
      expect(matches.size).to eq(1)
    end

    it "adds the association when the parent already includes the concern" do
      write_model("app/models/totp.rb", <<~RUBY)
        class Totp < ApplicationRecord
          include Vouch::BackupCodable

          def custom_backup_policy
            :retain
          end
        end
      RUBY

      run_generator(["totps"])

      body = read("app/models/totp.rb")
      expect(body.scan(/include Vouch::BackupCodable/).size).to eq(1)
      expect(body.scan(/has_many :backup_codes/).size).to eq(1)
      expect(body).to include("def custom_backup_policy")
    end

    it "adds the concern without replacing a custom backup-code association" do
      write_model("app/models/totp.rb", <<~RUBY)
        class Totp < ApplicationRecord
          has_many :backup_codes, class_name: "HostBackupCode", dependent: :nullify
        end
      RUBY

      run_generator(["totps"])

      body = read("app/models/totp.rb")
      expect(body.scan(/include Vouch::BackupCodable/).size).to eq(1)
      expect(body.scan(/has_many :backup_codes/).size).to eq(1)
      expect(body).to include('class_name: "HostBackupCode", dependent: :nullify')
    end

    [
      'has_many(:backup_codes, class_name: "HostBackupCode", dependent: :nullify)',
      'has_many "backup_codes", class_name: "HostBackupCode", dependent: :nullify'
    ].each do |association_declaration|
      it "recognizes #{association_declaration} as an existing association" do
        write_model("app/models/totp.rb", <<~RUBY)
          class Totp < ApplicationRecord
            #{association_declaration}
          end
        RUBY

        run_generator(["totps"])

        body = read("app/models/totp.rb")
        expect(body.scan(/include Vouch::BackupCodable/).size).to eq(1)
        expect(body.scan(/backup_codes/).size).to eq(1)
        expect(body).to include('class_name: "HostBackupCode", dependent: :nullify')
      end
    end

    it "keeps a fully generated parent idempotent" do
      write_model("app/models/totp.rb", "class Totp < ApplicationRecord\nend\n")

      run_full(["totps"])
      run_full(["totps"])

      body = read("app/models/totp.rb")
      expect(body.scan(/include Vouch::BackupCodable/).size).to eq(1)
      expect(body.scan(/has_many :backup_codes/).size).to eq(1)
      expect(File).to exist(File.join(tmpdir, "app/models/totp_backup_code.rb"))
      expect(Dir[File.join(tmpdir, "db/migrate/*_create_totp_backup_codes.rb")].size).to eq(1)
    end

    it "prints a wiring snippet when the parent model is missing" do
      output = run_generator(["totps"])
      expect(output).to match(/Add to app\/models\/totp\.rb/)
      expect(output).to match(/Vouch::BackupCodable/)
    end
  end
end
