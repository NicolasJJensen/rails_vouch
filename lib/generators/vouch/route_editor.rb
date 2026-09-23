# frozen_string_literal: true

require "ripper"

module Vouch
  module Generators
    module RouteEditor
      CONTROL_KEYWORDS = %w[if unless while until for case begin def class module].freeze
      WRAPPER = /\bVouch\s*\.\s*routes\b/
      DRAW = /\bRails\.application\.routes\.draw\b/
      WRAPPER_LINE = /\A[ \t]*Vouch\.routes\(\s*self\s*\)\s*do\s*\|\s*(\w+)\s*\|[ \t]*(?:#.*)?\r?\n?\z/
      DRAW_LINE = /\A[ \t]*Rails\.application\.routes\.draw\s+do[ \t]*(?:#.*)?\r?\n?\z/

      module_function

      def ensure_wrapper(path, wrapper)
        return :unsafe unless File.file?(path)

        source = File.read(path)
        return :unsafe unless Ripper.sexp(source)

        existing = statement_matches(source, WRAPPER)
        unless existing.empty?
          return matching_block(source, existing, WRAPPER_LINE) ? :exists : :unsafe
        end

        draw = matching_block(source, statement_matches(source, DRAW), DRAW_LINE)
        return :unsafe unless draw

        insert(path, source, draw, wrapper)
      end

      def insert_scope(path, block)
        return :unsafe unless File.file?(path)

        source = File.read(path)
        return :unsafe unless Ripper.sexp(source)

        wrapper = matching_block(source, statement_matches(source, WRAPPER), WRAPPER_LINE)
        return :unsafe unless wrapper

        wrapper_source = source.lines[wrapper.fetch(:start_line)..wrapper.fetch(:end_line)].join
        names = scope_names(Ripper.sexp(wrapper_source), wrapper.fetch(:variable))
        requested = scope_names(Ripper.sexp(block), "auth").first
        return :unsafe if requested.nil? || names.include?(nil)
        return :duplicate if names.include?(requested)

        insert(path, source, wrapper, block.gsub(/\bauth\./, "#{wrapper.fetch(:variable)}."))
      end

      # Insert one explicitly selected route inside an existing named scope.
      # The target must be a literal scope and a structurally unambiguous block.
      def insert_feature(path, scope_name, feature)
        return :unsafe unless File.file?(path)

        source = File.read(path)
        return :unsafe unless Ripper.sexp(source)
        wrapper = matching_block(source, statement_matches(source, WRAPPER), WRAPPER_LINE)
        return :unsafe unless wrapper

        receiver = Regexp.escape(wrapper.fetch(:variable))
        pattern = /^[ \t]*#{receiver}\.scope\b[^\n]*\bdo(?:[ \t]*\|[ \t]*(\w+)[ \t]*\|)?[ \t]*(?:#.*)?$/
        matches = source.to_enum(:scan, pattern).map { Regexp.last_match }
        matches.select! do |match|
          line = source[0...match.begin(0)].count("\n")
          declaration = match[0].sub(/\s+do\b.*$/, "")
          name = scope_names(Ripper.sexp(declaration), wrapper[:variable]).first
          line > wrapper[:start_line] && line < wrapper[:end_line] && name.to_s == scope_name.to_s
        end
        block = matching_block(source, matches, pattern)
        return :unsafe unless block

        variable = block[:variable] || wrapper[:variable]
        call = feature.split(".", 2).last
        method = call[/\A\w+/]
        body = source.lines[block[:start_line]..block[:end_line]].join
        return :duplicate if feature_call?(Ripper.sexp(body), variable, method)

        insert(path, source, block, "#{variable}.#{call}")
      end

      def feature_call?(node, variable, method)
        return false unless node.is_a?(Array)
        if %i[command_call call].include?(node[0])
          receiver = node[1]
          return true if %i[var_ref vcall].include?(receiver[0]) &&
            receiver.dig(1, 1) == variable && node.dig(3, 1) == method
        end
        node.any? { |child| child.is_a?(Array) && feature_call?(child, variable, method) }
      end

      def insert(path, source, block, content)
        lines = source.lines
        index = block.fetch(:end_line)
        indent = "#{lines[index][/\A[ \t]*/]}  "
        lines.insert(index, content.lines.map { |line| "#{indent}#{line}" }.join + "\n")
        candidate = lines.join
        return :unsafe unless Ripper.sexp(candidate)

        File.write(path, candidate)
        :inserted
      end

      # Use the complete token stream so text inside heredocs and comments is
      # never mistaken for executable route declarations.
      def statement_matches(source, pattern)
        starts = Ripper.lex(source).select { |_, type, _, _| type == :on_const }.map(&:first)
        source.to_enum(:scan, pattern).filter_map do
          match = Regexp.last_match
          prefix = source[0...match.begin(0)]
          position = [prefix.count("\n") + 1, prefix.split("\n", -1).last.to_s.bytesize]
          match if starts.include?(position)
        end
      end

      def matching_block(source, matches, line_pattern)
        return nil unless matches.one?

        match = matches.first
        start_line = source[0...match.begin(0)].count("\n")
        opener = line_pattern.match(source.lines[start_line])
        return nil unless opener

        depth = 0
        Ripper.lex(source).each do |position, type, value, _|
          next if position.first <= start_line || type != :on_kw
          return nil if CONTROL_KEYWORDS.include?(value)

          depth += 1 if value == "do"
          next unless value == "end"

          depth -= 1
          next unless depth.zero?

          end_line = position.first - 1
          return nil if end_line == start_line
          return nil unless source.lines[end_line].match?(/\A[ \t]*end[ \t]*(?:#.*)?\r?\n?\z/)

          return { start_line: start_line, end_line: end_line, variable: opener.captures.first }
        end
        nil
      end

      def scope_names(node, variable)
        return [] unless node.is_a?(Array)

        if node[0] == :command_call && scope_call?(node, variable)
          return [scope_name(node[4])]
        elsif node[0] == :method_add_arg && scope_call?(node[1], variable)
          args = node[2]
          return [scope_name(args[0] == :arg_paren ? args[1] : args)]
        elsif node[0] == :call && scope_call?(node, variable)
          return [nil]
        end

        node.flat_map { |child| scope_names(child, variable) }
      end

      def scope_call?(node, variable)
        return false unless node.is_a?(Array) && %i[command_call call].include?(node[0])

        receiver = node[1]
        %i[var_ref vcall].include?(receiver[0]) && receiver.dig(1, 1) == variable && node.dig(3, 1) == "scope"
      end

      def scope_name(args)
        return nil unless args && args[0] == :args_add_block && args[2] == false

        values = args[1]
        return nil unless values.is_a?(Array) && values.first.is_a?(Array)
        return literal_name(values.first) unless values.first[0] == :bare_assoc_hash

        pairs = values.first[1]
        return nil unless pairs.all? { |pair| pair[0] == :assoc_new && pair[1][0] == :@label }

        options = pairs.to_h { |pair| [pair[1][1], pair[2]] }
        reference = literal_name(options["model:"] || options["identity:"])
        reference&.underscore&.tr("/", "_")
      end

      def literal_name(node)
        return nil unless node.is_a?(Array)

        case node[0]
        when :symbol_literal
          token = node.dig(1, 1)
          token[1] if token && %i[@ident @op @const].include?(token[0])
        when :string_literal, :dyna_symbol
          content = node[1]
          content[1][1] if content && content.size == 2 && content.dig(1, 0) == :@tstring_content
        when :var_ref, :const_ref
          node[1][1] if node.dig(1, 0) == :@const
        when :const_path_ref
          parent = literal_name(node[1])
          "#{parent}::#{node[2][1]}" if parent
        end
      end
    end
  end
end
