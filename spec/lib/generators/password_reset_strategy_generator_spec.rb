require "spec_helper"
require "rails"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "generators/vouch/password_resetable/password_resetable_generator"

RSpec.describe Vouch::Generators::PasswordResetableGenerator do
  around do |example|
    Dir.mktmpdir("vouch-reset-strategy") do |directory|
      @directory = directory
      FileUtils.mkdir_p(File.join(directory, "app/models"))
      File.write(File.join(directory, "app/models/user.rb"), <<~RUBY)
        class User < ApplicationRecord
          include Vouch::Authenticatable
          authenticates_with :password_resetable, password_resetable: { expiry: 30.minutes }
        end
      RUBY
      example.run
    end
  end

  def generate(strategy = "signed", **options)
    generator = described_class.new(["User"], { token_strategy: strategy, model_only: true }.merge(options))
    generator.destination_root = @directory
    Dir.chdir(@directory) { generator.invoke_all }
  end

  def migrations
    Dir[File.join(@directory, "db/migrate/*.rb")]
  end

  it "preserves other model options and generates the signed schema only once" do
    2.times { generate }
    expect(migrations.length).to eq(1)
    expect(File.read(migrations.first)).to include("t.string :password_reset_nonce")
    model = File.read(File.join(@directory, "app/models/user.rb"))
    expect(model).to include("expiry: 30.minutes, token_strategy: :signed")
    expect(model.scan("authenticates_with").length).to eq(1)
    expect(Dir[File.join(@directory, "app/controllers/**/*")]).to be_empty
    expect(Dir[File.join(@directory, "app/mailers/**/*")]).to be_empty
  end

  it "changes configuration and emits a revocation migration when switching strategies back" do
    generate
    generate("opaque")
    generate
    expect(migrations.length).to eq(3)
    expect(File.read(migrations.last)).to include("direction.up", "= NULL")
    expect(File.read(File.join(@directory, "app/models/user.rb"))).to include("token_strategy: :signed")
    opaque = migrations.find { |path| path.include?("opaque") }
    expect(File.read(opaque)).to include("t.string :password_reset_token_digest, index: { unique: true }")
  end

  it "rejects a wrong existing nonce type even in a partial migration" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    File.write(File.join(@directory, "db/migrate/20260101000000_wrong.rb"), <<~RUBY)
      class Wrong < ActiveRecord::Migration[8.1]
        def change
          add_column :users, :password_reset_nonce, :integer
        end
      end
    RUBY
    expect { generate }.to raise_error(Thor::Error, /incompatible/)
  end

  it "preserves an explicit opaque strategy when rerun without an option" do
    generate("opaque")
    generator = described_class.new(["User"], model_only: true)
    generator.destination_root = @directory
    Dir.chdir(@directory) { generator.invoke_all }
    expect(migrations.length).to eq(1)
    expect(File.read(File.join(@directory, "app/models/user.rb"))).to include("token_strategy: :opaque")
  end

  it "inserts configuration before an inline comment" do
    path = File.join(@directory, "app/models/user.rb")
    File.write(path, "class User < ApplicationRecord\n  authenticates_with :password_resetable # application choice\nend\n")
    generate("opaque")
    source = File.read(path)
    expect(source).to match(/token_strategy: :opaque.*# application choice/)
    expect(Ripper.sexp(source)).not_to be_nil
  end

  it "preserves multiline options and rejects dynamic configuration before writing files" do
    path = File.join(@directory, "app/models/user.rb")
    File.write(path, "class User < ApplicationRecord\n  authenticates_with(\n    :password_resetable,\n    password_resetable: { expiry: 30.minutes }\n  )\nend\n")
    generate("opaque")
    expect(File.read(path)).to include("expiry: 30.minutes, token_strategy: :opaque")

    File.write(path, "class User < ApplicationRecord\n  authenticates_with :password_resetable, password_resetable: reset_options\nend\n")
    previous = migrations
    expect { generate }.to raise_error(Thor::Error, /explicitly/)
    expect(migrations).to eq(previous)
    expect(File.read(path)).to include("password_resetable: reset_options")
  end
end
