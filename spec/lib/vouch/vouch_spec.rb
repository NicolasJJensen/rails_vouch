# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch do
  describe ".configure" do
    it "yields the configuration" do
      Vouch.configure do |config|
        expect(config).to be_a(Vouch::Configuration)
      end
    end
  end

  describe ".configuration" do
    it "returns the configuration" do
      expect(Vouch.configuration).to be_a(Vouch::Configuration)
    end
  end

  describe ".verify!" do
    it "revalidates registered mappings" do
      expect(Vouch.verify!).to be(true)
    end

    it "requires at least one registered scope" do
      original = Vouch.mappings
      Vouch.instance_variable_set(:@mappings, {})
      expect { Vouch.verify! }.to raise_error(Vouch::ConfigurationError, /No Vouch scopes/)
    ensure
      Vouch.instance_variable_set(:@mappings, original)
    end
  end

  describe ".mappings" do
    it "returns a hash" do
      expect(Vouch.mappings).to be_a(Hash)
    end
  end

  describe ".mapping_for" do
    it "returns the mapping for a known scope" do
      Vouch.mappings[:test_scope] = Vouch::Mapping.new(
        :test_scope, model: "Account"
      )

      expect(Vouch.mapping_for(:test_scope)).to be_a(Vouch::Mapping)
    ensure
      Vouch.mappings.delete(:test_scope)
    end

    it "raises for an unknown scope" do
      expect {
        Vouch.mapping_for(:nonexistent)
      }.to raise_error(ArgumentError, /No Vouch mapping for scope :nonexistent/)
    end
  end

  describe "ConfigurationError" do
    it "is a StandardError" do
      expect(Vouch::ConfigurationError.new).to be_a(StandardError)
    end
  end
end
