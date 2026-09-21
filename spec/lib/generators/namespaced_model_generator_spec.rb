# frozen_string_literal: true

require "spec_helper"
require "rails"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/vouch/backup_codes/backup_codes_generator"
require "generators/vouch/invitations/invitations_generator"
require "generators/vouch/magic_linkable/magic_linkable_generator"
require "generators/vouch/recoverable/recoverable_generator"
require "generators/vouch/scope/scope_generator"
require "generators/vouch/verifiable/verifiable_generator"
require "vouch/model_metadata"

RSpec.describe Vouch::ModelMetadata do
  after do
    Array(@metadata_directories).each { |directory| FileUtils.rm_rf(directory) }
  end

  it "does not trigger an autoload while inspecting model metadata" do
    directory = Dir.mktmpdir("vouch-metadata-autoload")
    @metadata_directories ||= []
    @metadata_directories << directory
    path = File.join(directory, "phone.rb")
    File.write(path, "MetadataAutoload::Phone = Class.new\n")
    stub_const("MetadataAutoload", Module.new)
    MetadataAutoload.autoload(:Phone, path)

    metadata = described_class.new("MetadataAutoload::Phone")

    expect(metadata.table_name).to eq("metadata_autoload_phones")
    expect(metadata.class_name).to eq("MetadataAutoload::Phone")
    expect($LOADED_FEATURES).not_to include(path)
  end

  it "keeps class identity separate from a custom Active Model name" do
    model = Class.new do
      def self.model_name
        ActiveModel::Name.new(self, nil, "Credential")
      end

      def self.table_name
        "custom_name_phones"
      end
    end
    stub_const("CustomName", model)

    metadata = described_class.new("CustomName")

    expect(metadata.class_name).to eq("CustomName")
    expect(metadata.model_path).to eq("app/models/custom_name.rb")
    expect(metadata.param_key).to eq("credential")
  end

  it "supports singular table shorthand and slash namespace input" do
    expect(described_class.new("phone").table_name).to eq("phones")
    slash = described_class.new("admin/phones")
    expect(slash.class_name).to eq("Admin::Phone")
    expect(slash.table_name).to eq("admin_phones")
    expect(slash.model_path).to eq("app/models/admin/phone.rb")
  end
end

RSpec.describe "feature generators with namespaced models" do
  def generate(generator_class, args, options = {})
    directory = Dir.mktmpdir("vouch-namespaced-generator")
    FileUtils.mkdir_p(File.join(directory, "app/models/admin"))
    File.write(
      File.join(directory, "app/models/admin/phone.rb"),
      "module Admin\n  class Phone < ApplicationRecord\n  end\nend\n"
    )

    Dir.chdir(directory) do
      generator = generator_class.new(args, options)
      generator.destination_root = directory
      generator.invoke_all
    end

    @directories << directory
    directory
  end

  def generated_migration(directory, suffix)
    path = Dir[File.join(directory, "db/migrate", "*#{suffix}.rb")].fetch(0)
    [path, File.read(path)]
  end

  before { @directories = [] }
  after { @directories.each { |directory| FileUtils.rm_rf(directory) } }

  shared_examples "a namespaced feature migration" do |generator_class, feature|
    it "uses the model table, a flat migration path, and a valid migration class" do
      directory = generate(generator_class, ["Admin::Phone"])
      path, migration = generated_migration(directory, "add_#{feature}_to_admin_phones")

      expect(File.dirname(path)).to eq(File.join(directory, "db/migrate"))
      expect(migration).to include("class Add#{feature.camelize}ToAdminPhones")
      expect(migration).to include("change_table :admin_phones")
      expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
      expect(File.read(File.join(directory, "app/models/admin/phone.rb"))).to include(
        "include Vouch::#{generator_class.name.demodulize.delete_suffix('Generator')}"
      )
    end
  end

  include_examples "a namespaced feature migration",
                   Vouch::Generators::VerifiableGenerator,
                   "verifiable"
  include_examples "a namespaced feature migration",
                   Vouch::Generators::MagicLinkableGenerator,
                   "magic_linkable"

  it "generates namespaced backup-code artifacts and wires the parent model" do
    directory = generate(Vouch::Generators::BackupCodesGenerator, ["Admin::Phone"])
    path, migration = generated_migration(directory, "create_admin_phone_backup_codes")

    expect(File.dirname(path)).to eq(File.join(directory, "db/migrate"))
    expect(migration).to include("class CreateAdminPhoneBackupCodes")
    expect(migration).to include("create_table :admin_phone_backup_codes")
    expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error

    backup_code = File.join(directory, "app/models/admin/phone_backup_code.rb")
    expect(File.read(backup_code)).to include("class Admin::PhoneBackupCode")
    expect(File.read(backup_code)).to include('self.table_name = "admin_phone_backup_codes"')
    expect(File.read(backup_code)).to include(
      'belongs_to :admin_phone, class_name: "Admin::Phone"'
    )
    expect(File.read(File.join(directory, "app/models/admin/phone.rb"))).to include(
      'class_name: "Admin::PhoneBackupCode"'
    )
    expect(File.read(File.join(directory, "app/models/admin/phone.rb"))).to include(
      "foreign_key: :admin_phone_id"
    )
  end

  it "generates the invitation migration and controller under the model namespace" do
    directory = generate(
      Vouch::Generators::InvitationsGenerator,
      ["Admin::Phone", "Account"]
    )
    _path, migration = generated_migration(directory, "add_invitations_to_admin_phones")

    expect(migration).to include("class AddInvitationsToAdminPhones")
    expect(migration).to include("change_table :admin_phones")
    controller = File.join(directory, "app/controllers/admin/phones/invitations_controller.rb")
    expect(File.read(controller)).to include(
      "class Admin::Phones::InvitationsController < Vouch::InvitationsController"
    )
    expect(File.read(controller)).to include("auth_scope :phone")
    expect { RubyVM::InstructionSequence.compile_file(controller) }.not_to raise_error
  end

  it "keeps a namespaced recoverable migration at the migration root" do
    directory = generate(Vouch::Generators::RecoverableGenerator, ["Admin::Phone"])
    path, migration = generated_migration(directory, "add_recoverable_to_admin_phones")

    expect(File.dirname(path)).to eq(File.join(directory, "db/migrate"))
    expect(migration).to include("class AddRecoverableToAdminPhones")
    expect(migration).to include("change_table :admin_phones")
    expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
  end

  it "can target an invitation route scope independently of the identity model" do
    directory = generate(
      Vouch::Generators::InvitationsGenerator,
      ["Admin::Phone", "Account"],
      auth_scope: "user",
      controller_path: "users"
    )

    controller = File.join(directory, "app/controllers/users/invitations_controller.rb")
    contents = File.read(controller)
    expect(contents).to include("class Users::InvitationsController")
    expect(contents).to include("auth_scope :user")
  end

  it "uses metadata from an already-loaded model with a custom table name" do
    model = Class.new do
      def self.model_name
        ActiveModel::Name.new(self, nil, "MetadataPhone")
      end

      def self.table_name
        "legacy_phone_credentials"
      end
    end
    stub_const("MetadataPhone", model)
    directory = Dir.mktmpdir("vouch-custom-table-generator")
    @directories << directory
    FileUtils.mkdir_p(File.join(directory, "app/models"))
    File.write(
      File.join(directory, "app/models/metadata_phone.rb"),
      "class MetadataPhone < ApplicationRecord\nend\n"
    )

    Dir.chdir(directory) do
      generator = Vouch::Generators::VerifiableGenerator.new(["MetadataPhone"])
      generator.destination_root = directory
      generator.invoke_all
    end

    _path, migration = generated_migration(directory, "add_verifiable_to_legacy_phone_credentials")
    expect(migration).to include("change_table :legacy_phone_credentials")
    expect(File.read(File.join(directory, "app/models/metadata_phone.rb"))).to include(
      "include Vouch::Verifiable"
    )
  end

  it "preserves an explicit table string and the primary-key option" do
    directory = generate(
      Vouch::Generators::InvitationsGenerator,
      ["legacy_phone_credentials", "Account"],
      primary_key_type: "uuid"
    )
    _path, migration = generated_migration(directory, "add_invitations_to_legacy_phone_credentials")

    expect(migration).to include("change_table :legacy_phone_credentials")
    expect(migration).to include("type: :uuid")
  end

end
