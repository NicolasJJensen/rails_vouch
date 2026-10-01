require "rails_helper"
require "tmpdir"
require "rails/generators"
require "generators/vouch/verifiable/verifiable_generator"
require "generators/vouch/token_verifiable/token_verifiable_generator"

RSpec.describe "Composing verification generators" do
  generators = [Vouch::Generators::VerifiableGenerator, Vouch::Generators::TokenVerifiableGenerator]

  [generators, generators.reverse].each do |order|
    it "adds #{order.map(&:name).join(' then ')} without replacing shared schema or host delivery" do
      connection = ActiveRecord::Base.connection
      table = "vouch_verification_composition_#{SecureRandom.hex(4)}"
      connection.create_table(table) { |t| t.string :address }
      stub_const("ComposedContact", Class.new(ApplicationRecord) { self.table_name = table })
      Dir.mktmpdir("vouch-verification-composition") do |directory|
        FileUtils.mkdir_p("#{directory}/app/models")
        File.write("#{directory}/app/models/composed_contact.rb", <<~MODEL)
          class ComposedContact < ApplicationRecord
            self.verifiable_subject_attribute = :address
            def deliver_verification_code(code)
              MailDelivery.send_code(address, code)
            end
          end
        MODEL
        order.each do |generator_class|
          previous = Dir["#{directory}/db/migrate/*.rb"]
          generator = generator_class.new(["ComposedContact"], subject: ["ignored"])
          generator.destination_root = directory
          allow(generator).to receive(:generating_current_host?).and_return(true)
          generator.invoke_all
          source = File.read((Dir["#{directory}/db/migrate/*.rb"] - previous).sole)
          namespace = Module.new
          namespace.module_eval(source)
          namespace.const_get(source[/class (\w+)/, 1]).new.migrate(:up)
          ComposedContact.reset_column_information
        end
        expect(connection.columns(table).map(&:name)).to include("verified_at", "verification_nonce", "confirmation_nonce")
        source = File.read("#{directory}/app/models/composed_contact.rb")
        expect(source).to include("include Vouch::Verifiable", "include Vouch::TokenVerifiable::Concern", "MailDelivery.send_code")
        expect(source.scan("self.verifiable_subject_attribute").length).to eq(1)
        expect(source).not_to include(":ignored")
        expect(Dir["#{directory}/app/controllers/**/*"]).to be_empty
      end
    ensure
      connection.drop_table(table, if_exists: true) if table
    end
  end
end
