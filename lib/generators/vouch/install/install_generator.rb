# frozen_string_literal: true

require "rails/generators/base"

module Vouch
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install Vouch into the host app (initializer + locale)."

      def create_initializer
        template "initializer.rb", "config/initializers/vouch.rb"
      end

      def create_locale
        template "vouch.en.yml", "config/locales/vouch.en.yml"
      end

      def create_routes_block
        route_stub = <<~RUBY.indent(0)
          Vouch.routes(self) do |auth|
            # Add scopes with `bin/rails g vouch:scope <name> Account:account User:identity`
          end
        RUBY

        say_status :route, "Vouch.routes(self) (paste into config/routes.rb if not present)"
        say route_stub
      end
    end
  end
end
