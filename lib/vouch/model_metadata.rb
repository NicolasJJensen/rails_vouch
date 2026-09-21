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
