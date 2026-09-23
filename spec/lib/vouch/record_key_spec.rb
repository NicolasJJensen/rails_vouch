# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::RecordKey do
  let(:integer_type) do
    Class.new do
      def type = :integer
      def cast(value) = value.to_i
    end.new
  end

  let(:composite_model) do
    type = integer_type
    Class.new do
      define_singleton_method(:primary_key) { %w[tenant_id local_id] }
      define_singleton_method(:type_for_attribute) do |name|
        next type if name.to_s == "local_id"

        Class.new do
          def type = :string
          def cast(value) = value.to_s
        end.new
      end
    end
  end

  it "round trips typed string and integer components" do
    encoded = described_class.dump(["tenant-a", 7])

    expect(described_class.load(encoded)).to eq(["tenant-a", 7])
    expect(described_class.load(encoded).first).to be_a(String)
    expect(described_class.load(encoded).last).to be_a(Integer)
  end

  it "finds a composite key through the supplied scoped relation" do
    relation = instance_double("Relation", klass: composite_model)
    expect(relation).to receive(:find_by) do |attributes|
      expect(attributes).to eq("tenant_id" => "tenant-a", "local_id" => 7)
      :record
    end

    expect(described_class.find(relation, described_class.dump(["tenant-a", 7]))).to eq(:record)
  end

  it "keeps a scalar string primary key that resembles the transport prefix literal" do
    model = Class.new do
      define_singleton_method(:primary_key) { "code" }
      define_singleton_method(:type_for_attribute) do |_name|
        Class.new do
          def type = :string
          def cast(value) = value.to_s
        end.new
      end
    end

    value = "#{described_class::PREFIX}customer"
    expect(described_class.from_param(model, value)).to eq(value)
  end

  it "rejects partial integer casts and wrong composite arity" do
    model = Class.new do
      define_singleton_method(:primary_key) { "id" }
      define_singleton_method(:type_for_attribute) { |_name| IntegerTypeForRecordKeySpec.new }
    end
    stub_const("IntegerTypeForRecordKeySpec", Class.new do
      def type = :integer
      def cast(value) = value.to_i
    end)

    expect(described_class.from_param(model, "1junk")).to be_nil
    expect(described_class.from_param(composite_model, described_class.dump(["tenant-a"]))).to be_nil
  end

  it "rejects nonscalar values for scalar keys" do
    model = Class.new do
      define_singleton_method(:primary_key) { "id" }
      define_singleton_method(:type_for_attribute) do |_name|
        Class.new do
          def type = :string
          def cast(value) = value.to_s
        end.new
      end
    end

    expect(described_class.from_param(model, nil)).to be_nil
    expect(described_class.from_param(model, ["one", "two"])).to be_nil
    expect(described_class.from_param(model, {id: "one"})).to be_nil
  end

  it "rejects composite components that cast to nil" do
    model = Class.new do
      define_singleton_method(:primary_key) { %w[tenant_id local_id] }
      define_singleton_method(:type_for_attribute) do |name|
        Class.new do
          define_method(:type) { name.to_s == "local_id" ? :integer : :string }
          def cast(value)
            return nil if value == "invalid"

            value
          end
        end.new
      end
    end

    expect(described_class.from_param(model, described_class.dump(["invalid", 7]))).to be_nil
  end
end
