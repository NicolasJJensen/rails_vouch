# frozen_string_literal: true

require "digest"
require "ripper"

module Vouch
  module Generators
    module SchemaRepair
      private

      def schema_source(source)
        lines = source.lines
        offsets = [0]
        lines.each { |line| offsets << offsets.last + line.bytesize }
        masked = source.b.dup
        Ripper.lex(source).reverse_each do |position, kind, text, _state|
          next unless kind == :on_comment || (kind == :on_tstring_content && !text.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/))
          offset = offsets.fetch(position[0] - 1) + position[1]
          masked[offset, text.bytesize] = text.b.gsub(/[^\n]/, " ")
        end
        masked.force_encoding(source.encoding)
      end

      def repair_schema_constraints(table, required:, indexes:, foreign_keys: [])
        connection = ActiveRecord::Base.connection if generating_current_host?
        exists = connection&.data_source_exists?(table)
        columns = exists ? connection.columns(table).index_by(&:name) : {}
        source = Dir[File.join(destination_root, "db/migrate/*.rb")].filter_map do |path|
          schema_source(File.read(path))[/(?:create_table|change_table)\s*(?:\(\s*)?:#{Regexp.escape(table)}\b.*?^\s*end/m]
        end.join("\n")
        statements = []
        required.each do |column|
          required_in_source = source.match?(/t\.\w+\s+:#{Regexp.escape(column)}\b[^\n]*null:\s*false/)
          if column.end_with?("_id", "_type")
            association = column.sub(/_(id|type)\z/, "")
            required_in_source ||= source.match?(/t\.references\s+:#{Regexp.escape(association)}\b[^\n]*null:\s*false/)
          end
          next if exists && columns.key?(column) ? !columns.fetch(column).null : required_in_source
          statements << "change_column_null :#{table}, :#{column}, false"
        end
        indexes.each do |index|
          names = Array(index).map(&:to_s)
          present = if exists && names.all? { |name| columns.key?(name) }
            connection.index_exists?(table, names)
          elsif names.one?
            source.match?(/t\.\w+\s+:#{Regexp.escape(names.first)}\b[^\n]*index:\s*(?:true|\{)/) ||
              source.match?(/t\.index\s+:#{Regexp.escape(names.first)}\b/)
          else
            source.match?(/t\.index\s+#{Regexp.escape(names.inspect)}/)
          end
          if (!exists || names.any? { |name| !columns.key?(name) }) && names.length <= 2
            association = names.first.sub(/_(id|type)\z/, "")
            reference = source[/t\.references\s+:#{Regexp.escape(association)}\b[^\n]*/]
            present ||= reference && !reference.match?(/index:\s*false/)
          end
          next if present
          statements << "add_index :#{table}, #{names.inspect} unless index_exists?(:#{table}, #{names.inspect})"
        end
        foreign_keys.each do |foreign|
          keys = foreign.fetch(:column).map(&:to_s)
          primary = foreign.fetch(:primary_key).map(&:to_s)
          target = foreign.fetch(:to_table)
          present = exists ? connection.foreign_keys(table).any? { |key| key.to_table == target && Array(key.column).map(&:to_s) == keys && Array(key.primary_key).map(&:to_s) == primary } :
            source.include?("foreign_key: { to_table: :#{target}") || source.include?("t.foreign_key :#{target}")
          next if present
          statements << "add_foreign_key :#{table}, :#{target}, column: #{keys.inspect}, primary_key: #{primary.inspect} unless foreign_key_exists?(:#{table}, :#{target}, column: #{keys.inspect}, primary_key: #{primary.inspect})"
        end
        return if statements.empty?
        fingerprint = Digest::SHA256.hexdigest(statements.sort.join("\n"))[0, 10]
        name = "repair_#{table}_vouch_constraints_#{fingerprint}"
        return if Dir[File.join(destination_root, "db/migrate/*_#{name}.rb")].any?
        version = self.class.next_migration_number(File.join(destination_root, "db/migrate"))
        body = <<~SOURCE
          class #{name.camelize} < ActiveRecord::Migration[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]
            def change
              #{statements.join("\n    ")}
            end
          end
        SOURCE
        create_file "db/migrate/#{version}_#{name}.rb", body
      end
    end
  end
end
