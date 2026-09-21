# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/vouch/backup_codes/backup_codes_generator"
require "generators/vouch/magic_linkable/magic_linkable_generator"
require "generators/vouch/scope/scope_generator"
require "generators/vouch/verifiable/verifiable_generator"

RSpec.describe "namespaced generator installation", :generator_database do
  self.use_transactional_tests = false

  it "migrates and uses a generated namespaced scope with backup codes" do
    directory = Dir.mktmpdir("vouch-namespaced-installation")
    migration_classes = []
    namespace_name = "GeneratorIntegrationX#{SecureRandom.hex(6)}"
    model_name = "#{namespace_name}::Phone"
    phone_table = "#{namespace_name.underscore}_phones"
    backup_table = "#{namespace_name.underscore}_phone_backup_codes"

    Dir.chdir(directory) do
      scope_generator = Vouch::Generators::ScopeGenerator.new(
        ["phones", model_name],
        single_model: true
      )
      scope_generator.destination_root = directory
      scope_generator.invoke_all

      [Vouch::Generators::VerifiableGenerator,
       Vouch::Generators::MagicLinkableGenerator].each do |generator_class|
        generator = generator_class.new([model_name])
        generator.destination_root = directory
        generator.invoke_all
      end

      backup_generator = Vouch::Generators::BackupCodesGenerator.new([model_name])
      backup_generator.destination_root = directory
      backup_generator.invoke_all
    end

    Dir[File.join(directory, "db/migrate/*.rb")].sort.each do |path|
      load path
      class_name = File.basename(path).sub(/^\d+_/, "").delete_suffix(".rb").camelize
      migration_class = class_name.constantize
      migration_classes << class_name
      migration_class.migrate(:up)
    end

    stub_const(namespace_name, Module.new)
    load File.join(directory, "app/models", namespace_name.underscore, "phone.rb")
    load File.join(directory, "app/models", namespace_name.underscore, "phone_backup_code.rb")
    model_class = model_name.constantize
    delivered = {}
    model_class.verifiable_subject_attribute = :email_address
    model_class.define_method(:deliver_verification_code) { |code| delivered[:verification] = code }
    model_class.define_method(:deliver_sign_in_code) { |code| delivered[:sign_in] = code }

    phone = model_class.create!(email_address: "admin@example.test", password: "secret-value")
    verification = phone.start_verification!
    expect(phone.complete_verification!(delivered.fetch(:verification), token: verification.token)).to be_ok
    sign_in = phone.issue_sign_in_code!
    expect(phone.verify_sign_in_code(delivered.fetch(:sign_in), token: sign_in.token)).to be_ok

    code = phone.backup_codes.create!(code_digest: "digest")

    expect(code.public_send("#{namespace_name.underscore}_phone")).to eq(phone)
    expect(code.class.table_name).to eq(backup_table)
    expect(model_class.table_name).to eq(phone_table)
  ensure
    connection = ActiveRecord::Base.connection if ActiveRecord::Base.connected?
    [backup_table, phone_table].compact.each do |table|
      connection&.drop_table(table, if_exists: true)
    rescue ActiveRecord::StatementInvalid
      nil
    end
    migration_classes&.each do |class_name|
      Object.send(:remove_const, class_name) if Object.const_defined?(class_name, false)
    end
    FileUtils.rm_rf(directory) if directory
  end
end
