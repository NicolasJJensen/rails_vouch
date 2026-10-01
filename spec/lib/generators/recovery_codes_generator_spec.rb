# frozen_string_literal: true

require "spec_helper"
require "rails"
require "rails/generators"
require "fileutils"
require "tmpdir"
require "generators/vouch/recovery_codes/recovery_codes_generator"

RSpec.describe Vouch::Generators::RecoveryCodesGenerator do
  let(:directory) { Dir.mktmpdir("vouch-recovery-codes") }

  after { FileUtils.rm_rf(directory) }

  def write(path, contents)
    full_path = File.join(directory, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end

  def generate(*arguments, **options)
    generator = described_class.new(arguments, options)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
  end

  it "adds missing account recovery UI using the selected scope and controller path" do
    write "config/routes.rb", <<~RUBY
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :account, model: "Account", path: "portal/accounts" do
            auth.two_factor
          end
        end
      end
    RUBY

    generate "Account", auth_scope: "account", controller_path: "portal/accounts"

    expect(File).to exist(File.join(directory, "app/controllers/portal/accounts/recovery_codes_controller.rb"))
    expect(File.read(File.join(directory, "app/controllers/portal/accounts/recovery_codes_controller.rb"))).to include("Portal::Accounts::RecoveryCodesController")
    view = File.read(File.join(directory, "app/views/portal/accounts/recovery_codes/show.html.erb"))
    expect(view).to include("account_recovery_codes_path")
  end

  it "adds credential-owned recovery UI to the credential owner's custom scope" do
    write "app/models/phone.rb", <<~RUBY
      class Phone < ApplicationRecord
        belongs_to :user
      end
    RUBY
    write "app/models/user.rb", "class User < ApplicationRecord\nend\n"
    write "config/routes.rb", <<~RUBY
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :user, model: "User", path: "portal/users", as: :member do
            auth.two_factor
          end
        end
      end
    RUBY

    generate "Phone", owner: "User"

    expect(File).to exist(File.join(directory, "app/controllers/users/recovery_codes_controller.rb"))
    view = File.read(File.join(directory, "app/views/users/two_factor_challenge/recovery.html.erb"))
    expect(view).to include("member_consume_recovery_two_factor_challenge_path")
  end
  [false, true].each do |credential|
    [false, true].each do |polymorphic|
      it "generates #{polymorphic ? 'shared' : 'concrete'} storage for #{credential ? 'credential' : 'account'} recovery" do
        model = credential ? "Phone" : "User"
        write "app/models/user.rb", "class User < ApplicationRecord\nend\n"
        write "app/models/phone.rb", "class Phone < ApplicationRecord\n  belongs_to :user\nend\n" if credential
        options = { polymorphic: polymorphic }
        options[:owner] = "User" if credential
        generate model, **options
        table = polymorphic ? "recovery_codes" : "#{model.underscore}_recovery_codes"
        schema = File.read(Dir[File.join(directory, "db/migrate/*create_#{table}.rb")].sole)
        expect(schema).to include("t.string :code_digest", "t.datetime :used_at")
        expect(schema).to include(polymorphic ? "polymorphic: true" : "foreign_key: { to_table:")
        owner = File.read(File.join(directory, "app/models/#{model.underscore}.rb"))
        expect(owner).to include("recovery_codes_from :recovery_codes")
        expect(owner).to include(credential ? "include Vouch::BackupCodable" : "include Vouch::Recoverable")
        original = Dir[File.join(directory, "db/migrate/*")]
        generate model, **options
        expect(Dir[File.join(directory, "db/migrate/*")]).to eq(original)
      end
    end
  end

  it "rejects composite polymorphic generation before creating files" do
    allow_any_instance_of(Vouch::ModelMetadata).to receive(:primary_keys).and_return(%w[organisation_id number])
    expect { generate "User", polymorphic: true }.to raise_error(Thor::Error, /Composite recovery owners need concrete/)
    expect(Dir[File.join(directory, "db/migrate/*")]).to be_empty
  end

  it "preserves an explicitly selected custom relation" do
    write "app/models/user.rb", <<~RUBY
      class User < ApplicationRecord
        include Vouch::Recoverable
        has_many :emergency_codes, class_name: "EmergencyCode"
        recovery_codes_from :emergency_codes
      end
    RUBY
    generate "User"
    expect(Dir[File.join(directory, "db/migrate/*create*recovery_codes*")]).to be_empty
    expect(File.read(File.join(directory, "app/models/user.rb"))).not_to include("has_many :recovery_codes")
  end

  it "preserves a custom relation with the default recovery_codes name" do
    original = <<~RUBY
      class User < ApplicationRecord
        include Vouch::Recoverable
        has_many :recovery_codes, class_name: "EmergencyCode", foreign_key: :member_id
        recovery_codes_from :recovery_codes
      end
    RUBY
    write "app/models/user.rb", original
    generate "User"
    expect(Dir[File.join(directory, "db/migrate/*create*recovery_codes*")]).to be_empty
    expect(File.read(File.join(directory, "app/models/user.rb"))).to eq(original)
  end

  it "rejects an incompatible existing code model without replacing it" do
    original = "class UserRecoveryCode < ApplicationRecord\n  belongs_to :other\nend\n"
    write "app/models/user_recovery_code.rb", original
    expect { generate "User" }.to raise_error(Thor::Error, /must belong_to :user/)
    expect(File.read(File.join(directory, "app/models/user_recovery_code.rb"))).to eq(original)
  end

  it "rejects a code model pointing the owner association at another class" do
    write "app/models/user_recovery_code.rb", <<~RUBY
      class UserRecoveryCode < ApplicationRecord
        belongs_to :user, class_name: "Administrator"
      end
    RUBY
    expect { generate "User" }.to raise_error(Thor::Error, /must target User/)
  end

  it "rejects an incompatible pending shared key type instead of reusing its migration" do
    write "app/models/user.rb", "class User < ApplicationRecord\nend\n"
    write "app/models/phone.rb", "class Phone < ApplicationRecord\n  belongs_to :user\nend\n"
    generate "User", polymorphic: true
    paths = Dir[File.join(directory, "db/migrate/*")]
    expect { generate "Phone", owner: "User", polymorphic: true, primary_key_type: "uuid" }
      .to raise_error(Thor::Error, /uses bigint.*needs uuid/)
    expect { generate "Administrator", polymorphic: true, primary_key_type: "uuid" }
      .to raise_error(Thor::Error, /uses bigint.*needs uuid/)
    expect(Dir[File.join(directory, "db/migrate/*")]).to eq(paths)
    expect(File.read(File.join(directory, "app/models/phone.rb"))).not_to include("recovery_codes_from")
  end

end
