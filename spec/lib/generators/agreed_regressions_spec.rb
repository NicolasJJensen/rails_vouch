require 'spec_helper'
require 'rails'
require 'rails/generators'
require 'tmpdir'
require 'fileutils'
require 'ripper'
require 'generators/vouch/scope/scope_generator'

RSpec.describe 'Scope generator integration contracts' do
  around do |example|
    Dir.mktmpdir('auth-generator-contract') do |directory|
      @directory = directory
      FileUtils.mkdir_p("#{directory}/config")
      File.write("#{directory}/config/routes.rb", "Rails.application.routes.draw do\n  Vouch.routes(self) do |auth|\n  end\nend\n")
      example.run
    end
  end

  def generate(*args)
    generator = Vouch::Generators::ScopeGenerator.new(args)
    generator.destination_root = @directory
    Dir.chdir(@directory) { generator.invoke_all }
  end

  it 'emits the association used by a custom account model' do
    generate('members', 'Owner:account', 'Member:identity')
    routes = File.read("#{@directory}/config/routes.rb")
    expect(routes).to include('auth.scope :owner, model: "Owner"')
    expect(routes).to include('account_scope: :owner, identity: "Member"')
    expect(File.read("#{@directory}/app/models/member.rb")).to include('belongs_to :owner')
  end

  it 'generates valid Ruby and matching tables for namespaced models' do
    generate('staff', 'Admin::Account:account', 'Admin::User:identity', 'Admin::Organisation:tenant')
    Dir["#{@directory}/{app,db,config}/**/*.rb"].each do |path|
      expect { RubyVM::InstructionSequence.compile_file(path) }.not_to raise_error
    end
    identity = File.read("#{@directory}/app/models/admin/user.rb")
    expect(identity).to include('class_name: "Admin::Account"')
    expect(identity).to include('self.table_name = "admin_users"')
    migrations = Dir["#{@directory}/db/migrate/*.rb"].map { |path| File.read(path) }.join
    expect(migrations).to include('create_table :admin_users')
    expect(migrations).to include('to_table: :admin_accounts')
  end
  it 'inserts the new mapping after an existing customized feature block' do
    File.write("#{@directory}/config/routes.rb", <<~SOURCE)
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :existing, model: "Existing" do
            auth.sessions(path_names: {sign_in: "login"})
          end
        end
      end
    SOURCE
    generate('members', 'Owner:account', 'Member:identity')
    source = File.read("#{@directory}/config/routes.rb")
    expect(source).to match(/auth\.sessions\(path_names:.*\)\n\s+end\n\s+auth\.scope :owner/)
    expect(source).to include('auth.scope :member, account_scope: :owner')
    expect { RubyVM::InstructionSequence.compile(source) }.not_to raise_error
  end

  it 'keeps the generated scope inside the Vouch.routes DSL' do
    File.write("#{@directory}/config/routes.rb", <<~SOURCE)
      Rails.application.routes.draw do
        Vouch.routes(self) do |auth|
          auth.scope :existing, model: "Existing" do
            auth.sessions(path_names: {sign_in: "login"})
          end
        end
      end
    SOURCE
    generate('members', 'Owner:account', 'Member:identity')
    source = File.read("#{@directory}/config/routes.rb")
    route_start = source.lines.index { |line| line.include?('Vouch.routes(self)') }
    member_line = source.lines.index { |line| line.include?('auth.scope :member') }
    depth = 0
    member_depth = nil
    Ripper.lex(source).each do |(position, type, token, _state)|
      next if position.first < route_start + 1
      next unless type == :on_kw || type == :on_ident

      if token == 'do'
        depth += 1
      elsif token == 'end'
        depth -= 1
      elsif token == 'scope' && member_line && position.first == member_line + 1
        member_depth = depth
      end
    end

    expect(route_start).to be < member_line
    expect(member_depth).to eq(1)
  end

  it 'rejects unknown roles even in single-model mode' do
    generator = Vouch::Generators::ScopeGenerator.new(['staff', 'Admin::Account:unknown'], single_model: true)
    expect { generator.parse_pairs! }.to raise_error(Thor::Error, /Unknown role 'unknown'/)
  end

  it 'rejects duplicate model roles instead of silently replacing the first model' do
    generator = Vouch::Generators::ScopeGenerator.new(
      ['staff', 'FirstAccount:account', 'SecondAccount:account', 'User:identity']
    )

    expect { generator.parse_pairs! }.to raise_error(Thor::Error, /Duplicate role 'account'/)
  end

end
