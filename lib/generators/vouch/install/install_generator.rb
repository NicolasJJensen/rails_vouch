# frozen_string_literal: true

require "rails/generators/base"
require_relative "../route_editor"

module Vouch
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install Vouch configuration, locale, and route wrapper."

      def create_initializer
        template "initializer.rb", "config/initializers/vouch.rb"
      end

      def create_locale
        template "vouch.en.yml", "config/locales/vouch.en.yml"
      end

      def create_routes_block
        route_stub = <<~RUBY
          Vouch.routes(self) do |auth|
            # Add scopes with `bin/rails g vouch:scope <name> Account:account User:identity`
          end
        RUBY
        path = File.join(destination_root, "config/routes.rb")
        result = RouteEditor.ensure_wrapper(path, route_stub)
        if result == :inserted
          say_status :route, "Added Vouch.routes(self) to config/routes.rb", :green
        elsif result == :exists
          say_status :route, "Vouch.routes(self) already exists", :green
        else
          say_status :route, "Add Vouch.routes(self) to config/routes.rb", :yellow
          say route_stub
        end
      end
    end
  end
end
