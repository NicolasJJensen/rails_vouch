# frozen_string_literal: true

require "ripper"

module Vouch
  class ModelMetadata
    def initialize(input, root: Dir.pwd)
      @input = input.to_s
      @root = root
    end

    def class_name
      resolved_model&.name || conventional_class_name
    end

    def table_name
      resolved_model&.table_name || source_declarations["table_name"] || conventional_table_name
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
      Array(keys.presence || source_declarations["primary_key"].presence || database_primary_keys.presence || "id").map(&:to_s)
    end

    def primary_key_types
      model = resolved_model
      columns = if model.respond_to?(:columns_hash) && model.table_exists?
                  model.columns_hash
                elsif database_connection
                  database_connection.columns(table_name).index_by(&:name)
                else
                  {}
                end
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

    def source_declarations
      return @source_declarations if defined?(@source_declarations)
      path = File.join(@root, "app/models/#{conventional_class_name.underscore}.rb")
      @source_declarations = {}
      return @source_declarations unless File.file?(path)

      visit = lambda do |node, namespace, active|
        next unless node.is_a?(Array)
        case node[0]
        when :module, :class
          declared = constant_name(node[1])
          name = declared&.include?("::") ? declared : [namespace, declared].compact_blank.join("::")
          body = node[node[0] == :class ? 3 : 2]
          visit.call(body, name, name == conventional_class_name)
          next
        when :def, :defs
          next
        end
        if active && node[0] == :assign && node.dig(1, 0) == :field &&
            node.dig(1, 1, 1, 1) == "self" && %w[table_name primary_key].include?(node.dig(1, 3, 1))
          name = node.dig(1, 3, 1)
          value = literal_metadata(node[2])
          raise ArgumentError, "Load #{conventional_class_name} before generating: #{name} is not a literal declaration" if value.nil?
          @source_declarations[name] = value
        end
        node.each { |child| visit.call(child, namespace, active) if child.is_a?(Array) }
      end
      visit.call(Ripper.sexp(File.read(path)), nil, false)
      @source_declarations
    end

    def constant_name(node)
      return unless node.is_a?(Array)
      case node[0]
      when :const_ref, :var_ref, :top_const_ref then node.dig(1, 1)
      when :const_path_ref then [constant_name(node[1]), node.dig(2, 1)].compact.join("::")
      end
    end

    def literal_metadata(node)
      case node&.first
      when :string_literal
        content = node[1]
        content[1][1] if content.length == 2 && content.dig(1, 0) == :@tstring_content
      when :symbol_literal
        symbol = node[1]
        symbol[1][1] if symbol[0] == :symbol && %i[@ident @const].include?(symbol.dig(1, 0))
      when :array
        values = Array(node[1]).map { |child| literal_metadata(child) }
        values unless values.empty? || values.any?(&:nil?)
      end
    end

    def database_connection
      return @database_connection if defined?(@database_connection)
      @database_connection = if defined?(ActiveRecord::Base)
        connection = ActiveRecord::Base.connection
        connection if connection.data_source_exists?(table_name)
      end
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
      @database_connection = nil
    end

    def database_primary_keys
      database_connection&.primary_keys(table_name)
    end

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
