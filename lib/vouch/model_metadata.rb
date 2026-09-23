# frozen_string_literal: true

module Vouch
  class ModelMetadata
    def initialize(input)
      @input = input.to_s
    end

    def class_name
      resolved_model&.name || conventional_class_name
    end

    def table_name
      resolved_model&.table_name || conventional_table_name
    end

    def model_path
      "app/models/#{class_name.underscore}.rb"
    end

    def param_key
      resolved_model&.model_name&.param_key || class_name.underscore.tr("/", "_")
    end

    def association_key
      class_name.demodulize.underscore
    end

    def primary_keys
      model = resolved_model
      keys = if model&.respond_to?(:primary_keys)
               model.primary_keys
             elsif model&.respond_to?(:primary_key)
               model.primary_key
             end
      Array(keys.presence || "id").map(&:to_s)
    end

    def primary_key_types
      model = resolved_model
      columns = model.respond_to?(:columns_hash) && model.table_exists? ? model.columns_hash : {}
      primary_keys.to_h { |key| [key, columns[key]&.sql_type == "bigint" ? :bigint : (columns[key]&.type || :bigint)] }
    end

    def composite_primary_key?
      primary_keys.length > 1
    end

    def foreign_keys(prefix = association_key)
      composite_primary_key? ? primary_keys.map { |key| "#{prefix}_#{key}" } : ["#{prefix}_id"]
    end

    def association_options(prefix = association_key)
      keys = foreign_keys(prefix)
      foreign = keys.one? ? keys.first.to_sym.inspect : keys.inspect
      primary = primary_keys.one? ? primary_keys.first.to_sym.inspect : primary_keys.inspect
      "foreign_key: #{foreign}, primary_key: #{primary}"
    end

    def declaration_name(source)
      return class_name if source.match?(/^\s*class\s+#{Regexp.escape(class_name)}\b/)

      class_name.demodulize
    end

    private

    attr_reader :input

    def conventional_class_name
      input.sub(/\A::/, "").classify
    end

    def conventional_table_name
      return input if table_input?

      conventional_class_name.underscore.tr("/", "_").pluralize
    end

    def table_input?
      !input.include?("::") && !input.include?("/") &&
        !input.match?(/\A[A-Z]/) && input == input.pluralize
    end

    # Inspect only constants that are already loaded. Constantizing here can
    # invoke application autoloaders while generators run before migrations.
    def resolved_model
      return @resolved_model if defined?(@resolved_model)

      constant = conventional_class_name.split("::").reduce(Object) do |namespace, name|
        break if namespace.autoload?(name)
        break unless namespace.const_defined?(name, false)

        namespace.const_get(name, false)
      end
      @resolved_model = constant if constant.respond_to?(:model_name) && constant.respond_to?(:table_name)
    rescue NameError
      @resolved_model = nil
    end
  end
end
