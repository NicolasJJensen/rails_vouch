# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/string/inflections"
require "tmpdir"
require "generators/vouch/route_editor"

RSpec.describe Vouch::Generators::RouteEditor do
  let(:wrapper) { "Vouch.routes(self) do |auth|\nend\n" }
  let(:scope) { "auth.scope :user, model: \"User\" do\n  auth.sessions\nend\n" }

  around do |example|
    Dir.mktmpdir("vouch-routes") do |directory|
      @path = File.join(directory, "routes.rb")
      example.run
    end
  end

  def write(source)
    File.write(@path, source)
  end

  def in_wrapper(source)
    "Rails.application.routes.draw do\n  Vouch.routes(self) do |auth|\n#{source}\n  end\nend\n"
  end

  it "creates a wrapper alongside unrelated nested routes and preserves valid Ruby" do
    original = "Rails.application.routes.draw do\n  namespace :admin do\n    resources :reports\n  end\nend\n"
    write(original)
    expect(described_class.ensure_wrapper(@path, wrapper)).to eq(:inserted)
    expect(described_class.insert_scope(@path, scope)).to eq(:inserted)
    expect(File.read(@path)).to include("  namespace :admin do", "  Vouch.routes(self) do", "    auth.scope :user")
    expect(Ripper.sexp(File.read(@path))).not_to be_nil
    expect(described_class.ensure_wrapper(@path, wrapper)).to eq(:exists)
    expect(described_class.insert_scope(@path, scope)).to eq(:duplicate)
  end

  it "ignores wrapper text inside comments and multiline strings" do
    original = <<~'RUBY'
      # Vouch.routes(self) do |auth|
      note = <<~TEXT
        Vouch.routes(self) do |auth|
        end
      TEXT
      Rails.application.routes.draw do
      end
    RUBY
    write(original)
    expect(described_class.ensure_wrapper(@path, wrapper)).to eq(:inserted)
    expect(File.read(@path)).to start_with(original.split("Rails.application").first)
    expect(described_class.insert_scope(@path, scope)).to eq(:inserted)
  end

  [
    "Rails.application.routes.draw do; end\n",
    "Rails.application.routes.draw do\n  Vouch.routes(self) do |auth|; end\nend\n",
    "Rails.application.routes.draw do\n  Vouch.routes(self) { |auth| }\nend\n",
    "Rails.application.routes.draw do\n  if feature?\n  end\nend\n",
    "Rails.application.routes.draw do\n"
  ].each do |source|
    it "leaves unsupported or malformed route layouts untouched: #{source.lines[1]&.strip || source.strip}" do
      write(source)
      expect(described_class.ensure_wrapper(@path, wrapper)).to eq(:unsafe)
      expect(described_class.insert_scope(@path, scope)).to eq(:unsafe)
      expect(File.read(@path)).to eq(source)
    end
  end

  it "does not choose between multiple existing wrappers" do
    source = "Rails.application.routes.draw do\n#{wrapper}#{wrapper}end\n"
    write(source)
    expect(described_class.ensure_wrapper(@path, wrapper)).to eq(:unsafe)
    expect(described_class.insert_scope(@path, scope)).to eq(:unsafe)
    expect(File.read(@path)).to eq(source)
  end

  [
    'auth.scope :user do; end',
    'auth.scope(:"user", model: "User") do; end',
    "auth.scope model: 'User' do; end",
    'auth.scope(model: User) do; end',
    'auth.scope account: "Account", identity: "User" do; end',
    "auth.scope account: Account,\nidentity: User do; end"
  ].each do |declaration|
    it "recognizes an existing scope from #{declaration}" do
      source = in_wrapper(declaration)
      write(source)
      expect(described_class.insert_scope(@path, scope)).to eq(:duplicate)
      expect(File.read(@path)).to eq(source)
    end
  end

  it "does not confuse a differently named scope using the same model with a duplicate" do
    write(in_wrapper('auth.scope :operator, model: "User" do; end'))
    expect(described_class.insert_scope(@path, scope)).to eq(:inserted)
    expect(File.read(@path)).to include("auth.scope :operator", "auth.scope :user")
  end

  it "leaves dynamically named scopes untouched instead of guessing" do
    source = in_wrapper('auth.scope configured_name, model: "User" do; end')
    write(source)
    expect(described_class.insert_scope(@path, scope)).to eq(:unsafe)
    expect(File.read(@path)).to eq(source)
  end

  it "leaves scopes with splatted arguments untouched" do
    source = in_wrapper('auth.scope(*configured_arguments) do; end')
    write(source)
    expect(described_class.insert_scope(@path, scope)).to eq(:unsafe)
    expect(File.read(@path)).to eq(source)
  end

  it "uses an existing wrapper variable" do
    write(in_wrapper("").gsub("auth", "authentication"))
    expect(described_class.insert_scope(@path, scope)).to eq(:inserted)
    expect(File.read(@path)).to include("authentication.scope :user", "authentication.sessions")
  end

  it "rejects insertion content without a scope declaration" do
    source = in_wrapper("")
    write(source)
    expect(described_class.insert_scope(@path, "auth.sessions")).to eq(:unsafe)
    expect(File.read(@path)).to eq(source)
  end
  it "inserts a feature using the scope block variable without duplicating it" do
    write(in_wrapper(<<~RUBY))
      auth.scope :account, model: "Account" do |login|
        login.sessions
      end
    RUBY
    expect(described_class.insert_feature(@path, :account, "auth.password_resets")).to eq(:inserted)
    expect(File.read(@path)).to include("login.password_resets")
    expect(described_class.insert_feature(@path, :account, "auth.password_resets")).to eq(:duplicate)
  end

  it "does not mistake a commented feature for a configured route" do
    write(in_wrapper(<<~RUBY))
      auth.scope :account, model: "Account" do
        # auth.password_resets
        auth.sessions
      end
    RUBY
    expect(described_class.insert_feature(@path, :account, "auth.password_resets")).to eq(:inserted)
  end

  it "leaves conditional route blocks untouched instead of inserting into a nested branch" do
    original = in_wrapper(<<~RUBY)
      auth.scope :account, model: "Account" do
        if enabled?
          auth.sessions
        end
      end
    RUBY
    write(original)
    expect(described_class.insert_feature(@path, :account, "auth.password_resets")).to eq(:unsafe)
    expect(File.read(@path)).to eq(original)
  end

  it "adds a configured feature to an inferred scope without duplicating it" do
    write(in_wrapper(<<~RUBY))
      auth.scope model: "User" do
        auth.sessions
      end
    RUBY
    declaration = 'auth.password_resets controller: "portal/password_resets"'
    expect(described_class.insert_feature(@path, :user, declaration)).to eq(:inserted)
    expect(File.read(@path)).to include(declaration)
    expect(described_class.insert_feature(@path, :user, declaration)).to eq(:duplicate)
  end

  it "rejects a block without a scope declaration without changing the file" do
    original = in_wrapper("")
    write(original)
    expect(described_class.insert_scope(@path, "auth.sessions")).to eq(:unsafe)
    expect(File.read(@path)).to eq(original)
  end

end
