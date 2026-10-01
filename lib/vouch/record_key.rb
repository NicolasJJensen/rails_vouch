# frozen_string_literal: true

require "base64"
require "json"
require "date"
require "time"
require "bigdecimal"

module Vouch
  # Transports Active Record primary keys without relying on Array#to_s.
  #
  # Rails represents a composite primary key as an ordered Array.  Session,
  # token, and route values need a representation that survives cookie
  # serialization and keeps the value types (notably integers) intact.  The
  # payload contains only typed scalar values; it never contains a model name
  # and therefore never needs constantization while loading.
  module RecordKey
    PREFIX = "vouch-rk1_".freeze
    SUPPORTED_TYPES = %w[boolean float integer nil string date datetime time decimal].freeze

    class << self
      # Encode a record's declared primary key, or an explicit key value.
      # `model:` is useful when encoding an Array that is not a record.
      def dump(value, model: nil)
        key = key_for(value, model)
        values = key.is_a?(Array) ? key : [key]
        payload = {
          "v" => 1,
          "k" => values.map { |item| encode_value(item) }
        }
        PREFIX + Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      end

      # Decode a structured key. Returns a scalar for a scalar tuple and an
      # Array for a composite tuple; malformed input returns nil.
      def load(value)
        return nil unless value.is_a?(String) && value.start_with?(PREFIX)

        json = Base64.urlsafe_decode64(value.delete_prefix(PREFIX))
        payload = JSON.parse(json)
        return nil unless payload.is_a?(Hash) && payload.keys.sort == %w[k v] &&
          payload["v"] == 1 && payload["k"].is_a?(Array)

        decoded = payload["k"].map { |item| decode_value(item) }
        return nil if decoded.any? { |item| item.equal?(INVALID) }

        decoded.length == 1 ? decoded.first : decoded
      rescue ArgumentError, JSON::ParserError, TypeError
        nil
      end

      # Return a route-safe value. Scalar keys retain Rails' established
      # parameter format; composite keys use the typed transport.
      def to_param(record)
        return record.id.to_s unless record.class.respond_to?(:primary_key)

        primary_key = record.class.primary_key
        return dump(record) if primary_key.is_a?(Array)

        key = read_key(record, primary_key)
        case key
        when Time, DateTime then key.iso8601(9)
        when BigDecimal then key.to_s("F")
        else key.to_s
        end
      end

      # Decode a route value into a key suitable for querying a model. Scalar
      # values are cast through the model's declared primary-key type.
      def from_param(model_or_relation, value)
        model = model_for(model_or_relation)
        primary_key = model.primary_key
        return nil if value.nil? || value.is_a?(Array) || value.is_a?(Hash)

        if primary_key.is_a?(Array)
          decoded = load(value)
          decoded = value if value.is_a?(Array)
          return cast_key(model, primary_key, decoded) if decoded.is_a?(Array) && decoded.length == primary_key.length

          return nil
        end

        cast_key(model, [primary_key], [value])&.first
      rescue ArgumentError, NoMethodError
        nil
      end

      # Find within the supplied relation, preserving all scopes and joins.
      # Invalid and missing keys raise RecordNotFound, just like Relation#find.
      def find(relation, value, model: nil)
        model ||= model_for(relation)
        key = from_param(model, value)
        raise_record_not_found(value) if key.nil?

        primary_key = model.primary_key
        attributes = if primary_key.is_a?(Array)
          primary_key.zip(key).to_h
        else
          {primary_key => key}
        end
        record = if relation.respond_to?(:find_by)
          if primary_key.is_a?(Array)
            relation.find_by(attributes)
          else
            relation.find_by(primary_key => key)
          end
        elsif relation.respond_to?(:find) && !primary_key.is_a?(Array)
          relation.find(key)
        end
        return record if record

        raise_record_not_found(value)
      end

      def same?(left, right, model: nil)
        left_key = comparable_key(key_for(left, model))
        right_key = comparable_key(key_for(right, model))
        left_key.is_a?(Array) || right_key.is_a?(Array) ? left_key == right_key : left_key.to_s == right_key.to_s
      end

      # Representation used in sessions and signed token payloads. Legacy
      # scalar payloads remain plain Rails IDs for compatibility.
      def serialize(record)
        to_param(record)
      end

      # Storage value for signed payloads that historically carried a native
      # scalar ID. Composite keys use the structured transport; date, time and
      # decimal scalars use lossless strings across JSON session serialization.
      def value(record)
        return record.id unless record.class.respond_to?(:primary_key)

        primary_key = record.class.primary_key
        return dump(record) if primary_key.is_a?(Array)

        key = read_key(record, primary_key)
        key.is_a?(Date) || key.is_a?(Time) || key.is_a?(BigDecimal) ? to_param(record) : key
      end

      def attributes_for(record)
        return {id: record.id} unless record.class.respond_to?(:primary_key)

        primary_key = record.class.primary_key
        key = read_key(record, primary_key)
        primary_key.is_a?(Array) ? primary_key.zip(key).to_h : {primary_key => key}
      end

      private

      INVALID = Object.new.freeze

      def key_for(value, model)
        if record?(value)
          primary_key = value.class.primary_key
          return read_key(value, primary_key)
        end

        if model && model.respond_to?(:primary_key) && model.primary_key.is_a?(Array)
          loaded = load(value)
          return loaded unless loaded.nil?
        end

        return value.id if model.nil? && value.respond_to?(:id) && !value.is_a?(Array)

        return value if model.nil?

        return value unless model.respond_to?(:primary_key)

        value
      end

      def comparable_key(value)
        value.is_a?(Array) ? value.map(&:to_s) : value
      end

      def cast_key(model, primary_key, values)
        primary_key.zip(values).map do |attribute, value|
          return nil if value.nil? || value.is_a?(Array) || value.is_a?(Hash)

          type = model.type_for_attribute(attribute.to_s) if model.respond_to?(:type_for_attribute)
          if type&.type == :integer
            return nil unless value.is_a?(Integer) || value.to_s.match?(/\A[+-]?\d+\z/)
          elsif type&.type == :string || type&.type == :uuid
            return nil unless value.is_a?(String)
          elsif [:decimal, :float].include?(type&.type)
            return nil unless value.to_s.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)
          elsif type&.type == :date && value.is_a?(String)
            Date.iso8601(value)
          elsif type&.type == :datetime && value.is_a?(String)
            Time.iso8601(value)
          end
          casted = type ? type.cast(value) : value
          return nil if casted.nil? || (casted.respond_to?(:finite?) && !casted.finite?)

          casted
        end
      end

      def read_key(record, primary_key)
        return primary_key.map { |attribute| record.public_send(attribute) } if primary_key.is_a?(Array)

        record.public_send(primary_key)
      end

      def record?(value)
        value.respond_to?(:class) && value.class.respond_to?(:primary_key) && value.respond_to?(:persisted?)
      end

      def model_for(model_or_relation)
        return model_or_relation.klass if model_or_relation.respond_to?(:klass)
        model_or_relation
      end

      def encode_value(value)
        type = case value
               when nil then "nil"
               when true, false then "boolean"
               when Integer then "integer"
               when Float then "float"
               when String then "string"
               when DateTime then "datetime"
               when Date then "date"
               when Time then "time"
               when BigDecimal then "decimal"
               else
                 raise ArgumentError, "unsupported primary-key value type: #{value.class}"
               end
        serialized = case type
                     when "date" then value.iso8601
                     when "datetime", "time" then value.iso8601(9)
                     when "decimal" then value.to_s("F")
                     else value
                     end
        { "t" => type, "v" => serialized }
      end

      def decode_value(value)
        return INVALID unless value.is_a?(Hash) && SUPPORTED_TYPES.include?(value["t"])

        case value["t"]
        when "nil" then nil
        when "boolean" then value["v"] == true || value["v"] == false ? value["v"] : INVALID
        when "integer" then value["v"].is_a?(Integer) ? value["v"] : INVALID
        when "float" then value["v"].is_a?(Numeric) ? value["v"] : INVALID
        when "string" then value["v"].is_a?(String) ? value["v"] : INVALID
        when "date" then value["v"].is_a?(String) ? Date.iso8601(value["v"]) : INVALID
        when "datetime" then value["v"].is_a?(String) ? DateTime.iso8601(value["v"]) : INVALID
        when "time" then value["v"].is_a?(String) ? Time.iso8601(value["v"]) : INVALID
        when "decimal" then value["v"].is_a?(String) ? BigDecimal(value["v"]) : INVALID
        else INVALID
        end
      end

      def raise_record_not_found(value)
        raise ::ActiveRecord::RecordNotFound, "could not find record for key #{value.inspect}"
      end
    end
  end
end
