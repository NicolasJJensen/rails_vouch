require "rails_helper"
require "rails/generators"
require "tmpdir"
require "generators/vouch/password_trackable/password_trackable_generator"
require "generators/vouch/lockable/lockable_generator"

RSpec.describe "Password history and lockout generation" do
  def generate(directory, klass, model = "Person", options = {})
    generator = klass.new([model], options)
    generator.destination_root = directory
    Dir.chdir(directory) { generator.invoke_all }
    generator
  end

  around do |example|
    Dir.mktmpdir("vouch-history-lockout") do |directory|
      @directory = directory
      FileUtils.mkdir_p(File.join(directory, "app/models"))
      File.write(File.join(directory, "app/models/person.rb"), "class Person < ApplicationRecord\nend\n")
      example.run
    end
  end

  let(:history_generator) { Vouch::Generators::PasswordTrackableGenerator }
  let(:lockout_generator) { Vouch::Generators::LockableGenerator }
  let(:migrations) { Dir[File.join(@directory, "db/migrate/*.rb")] }

  it "generates natural ownership and does not duplicate it on rerun" do
    2.times { generate(@directory, history_generator) }
    expect(migrations.length).to eq(1)
    expect(File.read(migrations.first)).to include("t.references :person", "index: false", '["person_id", "created_at"]')
    expect(File.read(File.join(@directory, "app/models/password_archive.rb"))).to include('belongs_to :person, class_name: "Person"')
    person = File.read(File.join(@directory, "app/models/person.rb"))
    expect(person.scan("authenticates_with :password_trackable").length).to eq(1)
    expect(person.scan("has_many :password_archives").length).to eq(1)
  end

  it "uses owner for explicitly shared storage" do
    generate(@directory, history_generator, "Person", polymorphic: true)
    expect(File.read(migrations.first)).to include("t.references :owner, polymorphic: true")
    expect(File.read(File.join(@directory, "app/models/person.rb"))).to include("has_many :password_archives, as: :owner")
    expect { generate(@directory, history_generator, "Person", polymorphic: true) }.not_to raise_error
  end

  it "rejects converting an existing concrete archive to polymorphic ownership" do
    generate(@directory, history_generator)
    original = File.read(File.join(@directory, "app/models/person.rb"))
    expect { generate(@directory, history_generator, "Person", polymorphic: true) }.to raise_error(Thor::Error, /ownership/)
    expect(File.read(File.join(@directory, "app/models/person.rb"))).to eq(original)
    expect(migrations.length).to eq(1)
  end

  it "rejects wiring another concrete owner to an existing archive" do
    generate(@directory, history_generator)
    expect { generate(@directory, history_generator, "Operator") }.to raise_error(Thor::Error, /ownership/)
  end

  it "does not silently preserve an owner association pointing at different keys" do
    File.write(File.join(@directory, "app/models/person.rb"), <<~RUBY)
      class Person < ApplicationRecord
        has_many :password_archives, foreign_key: :someone_else_id
      end
    RUBY
    expect { generate(@directory, history_generator) }.to raise_error(Thor::Error, /association is incompatible/)
    expect(migrations).to be_empty
  end

  it "rejects an incompatible pending archive migration before wiring the owner" do
    FileUtils.mkdir_p(File.join(@directory, "db/migrate"))
    File.write(File.join(@directory, "db/migrate/20261001000000_create_password_archives.rb"), <<~RUBY)
      create_table :password_archives do |t|
        t.references :operator
        t.string :password_digest
        t.datetime :created_at
      end
    RUBY
    expect { generate(@directory, history_generator) }.to raise_error(Thor::Error, /Pending password_archives/)
    expect(File.read(File.join(@directory, "app/models/person.rb"))).not_to include("authenticates_with")
  end

  it "keeps custom and composite concrete foreign keys in the migration" do
    metadata = instance_double(Vouch::ModelMetadata,
      class_name: "Person", model_path: "app/models/person.rb", association_key: "person",
      primary_keys: %w[region number], primary_key_types: { "region" => :string, "number" => :bigint },
      foreign_keys: %w[person_region person_number], association_options: 'foreign_key: ["person_region", "person_number"], primary_key: ["region", "number"]',
      composite_primary_key?: true, table_name: "people", declaration_name: "Person")
    allow(Vouch::ModelMetadata).to receive(:new).with("Person").and_return(metadata)
    generate(@directory, history_generator)
    source = File.read(migrations.first)
    expect(source).to include("t.string :person_region", "t.bigint :person_number")
    expect(source).to include('column: ["person_region", "person_number"], primary_key: ["region", "number"]')
  end

  it "rejects a pending foreign key to a different table" do
    generate(@directory, history_generator)
    File.write(migrations.first, File.read(migrations.first).sub("to_table: :people", "to_table: :operators"))
    expect { generate(@directory, history_generator) }.to raise_error(Thor::Error, /Pending password_archives/)
  end

  it "wires lockout once and preserves an existing multiline feature declaration" do
    path = File.join(@directory, "app/models/person.rb")
    File.write(path, <<~RUBY)
      class Person < ApplicationRecord
        include Vouch::Authenticatable
        authenticates_with :password_trackable,
          :lockable
      end
    RUBY
    2.times { generate(@directory, lockout_generator) }
    expect(File.read(path).scan(":lockable").length).to eq(1)
    expect(migrations.length).to eq(1)
    expect(File.read(migrations.first)).to include("t.datetime :locked_at, index: true")
  end

  it "adds lockout to an existing model that has no authentication declaration" do
    generate(@directory, lockout_generator)
    expect(File.read(File.join(@directory, "app/models/person.rb"))).to include(
      "include Vouch::Authenticatable", "authenticates_with :lockable")
  end

  it "executes the generated history migration with its foreign key and owner/time index" do
    generate(@directory, history_generator)
    connection = ActiveRecord::Base.connection
    original_path = connection.schema_search_path
    schema = "vouch_history_generator"
    connection.create_schema(schema)
    connection.schema_search_path = schema
    connection.create_table(:people)
    namespace = Module.new
    namespace.module_eval(File.read(migrations.first), migrations.first)
    ActiveRecord::Migration.suppress_messages { namespace.const_get(:CreatePasswordArchives).new.migrate(:up) }

    expect(connection.foreign_keys(:password_archives).map(&:to_table)).to eq(["people"])
    expect(connection.indexes(:password_archives).map(&:columns)).to eq([%w[person_id created_at]])
  ensure
    if connection && original_path
      connection.schema_search_path = original_path
      connection.drop_schema(schema, if_exists: true)
    end
  end
end
