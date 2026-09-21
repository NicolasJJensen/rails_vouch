# frozen_string_literal: true

require "rails/generators/base"
require "ripper"

module Vouch
  module Generators
    class ImpersonationGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      STRUCTURAL_KEYWORDS = %w[if unless while until for case begin def class module].freeze

      argument :scope, type: :string, default: "users", banner: "scope"
      class_option :auth_scope, type: :string, default: nil,
                                desc: "Authentication scope for the generated controller and route insertion"

      desc "Add an impersonation route and a host-owned authorization controller."

      def create_controller
        path = "app/controllers/#{scope}/impersonations_controller.rb"
        return say_status(:controller, "exists  #{path}") if File.exist?(File.join(destination_root, path))

        template "impersonations_controller.rb.tt", path
      end

      def add_route
        routes_path = File.join(destination_root, "config/routes.rb")
        return manual_route_instruction unless File.file?(routes_path)

        lines = File.readlines(routes_path)
        starts = lines.each_index.select { |index| scope_declaration?(lines[index]) }
        return manual_route_instruction unless starts.one?

        scope_block = scope_block(lines, starts.first)
        return manual_route_instruction unless scope_block
        finish, receiver = scope_block
        return say_status(:route, "exists  auth.impersonation") if impersonation_route?(lines, starts.first, finish)

        indent = lines[starts.first][/\A\s*/] + "  "
        lines.insert(finish, "#{indent}#{receiver}.impersonation controller: #{controller_path.inspect}\n")
        File.write(routes_path, lines.join)
        say_status :route, "added  auth.impersonation inside :#{auth_scope_name}"
      end

      private

      def auth_scope_name
        (options[:auth_scope].presence || scope.singularize).to_sym
      end

      def controller_class_name
        "#{scope.camelize}::ImpersonationsController"
      end

      def scope_declaration?(line)
        line.match?(/^\s*[a-zA-Z_]\w*\.scope\s+:#{Regexp.escape(auth_scope_name.to_s)}(?:\s|,|$)/)
      end

      def scope_block(lines, start)
        depth = 0
        opened = false
        receiver = block_receiver(lines[start])
        return nil unless receiver

        Ripper.lex(lines[start..].join).each do |position, type, value, _state|
          next unless type == :on_kw
          return nil if STRUCTURAL_KEYWORDS.include?(value)

          if value == "do"
            opened = true
            depth += 1
          elsif value == "end" && opened
            depth -= 1
            return [start + position.first - 1, receiver] if depth.zero?
          end
        end

        nil
      end

      def block_receiver(line)
        scope_receiver = line[/^\s*([a-zA-Z_]\w*)\.scope\b/, 1]
        block_receiver = line[/\bdo\s*\|\s*([a-zA-Z_]\w*)\s*\|/, 1]
        block_receiver || scope_receiver
      end

      def impersonation_route?(lines, start, finish)
        lines[(start + 1)...finish].any? { |line| line.match?(/^\s*[a-zA-Z_]\w*\.impersonation(?:\s|$)/) }
      end

      def manual_route_instruction
        say_status :route, "manual  add auth.impersonation inside the existing auth.scope :#{auth_scope_name} block"
      end

      def controller_path
        "#{scope}/impersonations"
      end
    end
  end
end
