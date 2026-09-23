# frozen_string_literal: true

require "spec_helper"
require "rails"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "generators/vouch/omniauth/omniauth_generator"

RSpec.describe Vouch::Generators::OmniauthGenerator do
  let(:directory) { Dir.mktmpdir("vouch-omniauth-generator") }

  after { FileUtils.rm_rf(directory) }

  it "defaults the owner scope to users" do
    argument = described_class.arguments.find { |candidate| candidate.name.to_s == "scope" }

    expect(argument.default).to eq("users")
  end

  it "generates a non-polymorphic User-owned identity and wires the user" do
    Dir.chdir(directory) do
      generator = described_class.new([], primary_key_type: "uuid")
      generator.destination_root = directory
      FileUtils.mkdir_p(File.join(directory, "app/models"))
      File.write(File.join(directory, "app/models/user.rb"), "class User < ApplicationRecord\nend\n")
      generator.invoke_all
    end

    migration = File.read(Dir[File.join(directory, "db/migrate/*oauth_identities.rb")].fetch(0))
    model = File.read(File.join(directory, "app/models/oauth_identity.rb"))
    account = File.read(File.join(directory, "app/models/user.rb"))

    expect(model).to include("class OauthIdentity < ApplicationRecord")
    expect(model).to include("belongs_to :user")
    expect(model).not_to include("polymorphic")
    expect(account).to include('has_many :oauth_identities, class_name: "OauthIdentity"')
    expect(account).to include("foreign_key: :user_id, primary_key: :id, dependent: :destroy")
    expect(migration).to include("t.uuid :user_id, null: false", "add_foreign_key :oauth_identities, :users")
    expect(migration).not_to include("polymorphic")
    expect(migration).to include("t.string :provider, null: false")
    expect(migration).to include("t.string :uid, null: false")
    expect(migration).to include("t.json :auth_data")
    expect(migration).not_to include(":access_token")
    expect(migration).not_to include(":refresh_token")
    expect(migration).not_to include(":token_expires_at")
    expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
  end

  it "uses the selected single-model owner for its identity and association" do
    Dir.chdir(directory) do
      FileUtils.mkdir_p(File.join(directory, "app/models"))
      File.write(File.join(directory, "app/models/member.rb"), "class Member < ApplicationRecord\nend\n")
      generator = described_class.new(["members"])
      generator.destination_root = directory
      generator.invoke_all
    end

    migration = File.read(Dir[File.join(directory, "db/migrate/*oauth_identities.rb")].fetch(0))
    model = File.read(File.join(directory, "app/models/oauth_identity.rb"))
    member = File.read(File.join(directory, "app/models/member.rb"))

    expect(model).to include("belongs_to :member")
    expect(member).to include("foreign_key: :member_id, primary_key: :id, dependent: :destroy")
    expect(migration).to include("t.bigint :member_id, null: false", "add_foreign_key :oauth_identities, :members")
  end

  it "does not duplicate an editable owner association" do
    Dir.chdir(directory) do
      FileUtils.mkdir_p(File.join(directory, "app/models"))
      File.write(File.join(directory, "app/models/account.rb"), <<~RUBY)
        class Account < ApplicationRecord
          has_many :oauth_identities, class_name: "OauthIdentity", foreign_key: :account_id, dependent: :destroy
        end
      RUBY
      generator = described_class.new([])
      generator.destination_root = directory
      generator.invoke_all
    end

    account = File.read(File.join(directory, "app/models/account.rb"))

    expect(account.scan("has_many :oauth_identities").length).to eq(1)
  end
end
