# frozen_string_literal: true

require "rails/generators"
require "rails/generators/actions"
require "rails/generators/base"

module Vouch
  module Generators
    # Copy a base controller from the gem into the host app so it can be
    # customised directly. The source body is read from
    # app/controllers/vouch/* in the gem at generation time and
    # the class declaration is rewritten for the host scope.
    #
    #   bin/rails g vouch:eject users sessions
    #   bin/rails g vouch:eject admins password_resets
    #
    class EjectGenerator < Rails::Generators::Base
      argument :scope,           type: :string, banner: "scope"
      argument :controller_name, type: :string, banner: "controller_name"

      class_option :auth_scope, type: :string, default: nil,
                                desc: "Authentication scope for the emitted controller (independent of its namespace)"

      CONTROLLERS = {
        "sessions"               => "SessionsController",
        "membership_sessions"    => "MembershipSessionsController",
        "registrations"          => "RegistrationsController",
        "password_resets"        => "PasswordResetsController",
        "invitations"            => "InvitationsController",
        "two_factor_challenge"   => "TwoFactorChallengeController",
        "two_factor_credentials" => "TwoFactorCredentialsController",
        "recovery_codes"         => "RecoveryCodesController",
        "omni_auths"             => "OmniAuthsController",
        "impersonations"         => "ImpersonationsController"
      }.freeze

      desc "Copy a gem controller into app/controllers/<scope>/ for customisation."

      def validate!
        return if CONTROLLERS.key?(controller_name)

        raise Thor::Error,
              "Unknown controller '#{controller_name}'. Valid: #{CONTROLLERS.keys.join(', ')}"
      end

      def copy_controller
        implementation = "app/controllers/#{scope}/#{controller_name}_implementation_controller.rb"
        target = "app/controllers/#{scope}/#{controller_name}_controller.rb"
        create_file implementation, rewrite_class_declaration(File.read(source_path)) unless File.file?(File.join(destination_root, implementation))
        if File.file?(File.join(destination_root, target))
          rewrite_host_superclass(target)
        else
          create_file target, host_controller_body
        end
      end

      private

      def source_path
        gem_root = Gem.loaded_specs["rails_vouch"]&.full_gem_path ||
                   File.expand_path("../../../..", __dir__)

        File.join(gem_root, "app/controllers/vouch/#{source_controller_name}_controller.rb")
      end

      def source_controller_name
        target = File.join(destination_root, "app/controllers/#{scope}/#{controller_name}_controller.rb")
        return controller_name unless controller_name == "sessions" && File.file?(target)

        File.read(target).include?("Vouch::MembershipSessionsController") ? "membership_sessions" : controller_name
      end

      def rewrite_class_declaration(body)
        class_name = CONTROLLERS.fetch(source_controller_name)
        body.sub(
          "class Vouch::#{class_name}",
          "class #{implementation_class}"
        )
      end

      def implementation_class
        "#{scope.camelize}::#{CONTROLLERS.fetch(controller_name).sub(/Controller\z/, "")}ImplementationController"
      end

      def host_class
        "#{scope.camelize}::#{CONTROLLERS.fetch(controller_name)}"
      end

      def host_controller_body
        scope_line = options[:auth_scope].present? ? "\n  auth_scope #{options[:auth_scope].to_sym.inspect}" : ""
        "class #{host_class} < #{implementation_class}#{scope_line}\nend\n"
      end

      def rewrite_host_superclass(target)
        path = File.join(destination_root, target)
        source = File.read(path)
        unless source.match?(/class\s+#{Regexp.escape(host_class)}\s*</)
          raise Thor::Error, "Ejection requires a #{host_class} class declaration; nested module syntax is not supported yet."
        end
        rewritten = source.sub(/class\s+#{Regexp.escape(host_class)}\s*<\s*[^\n]+/, "class #{host_class} < #{implementation_class}")
        if options[:auth_scope].present? && !rewritten.match?(/^\s*auth_scope\b/)
          rewritten = rewritten.sub(/(class\s+#{Regexp.escape(host_class)}[^\n]*\n)/, "\\1  auth_scope #{options[:auth_scope].to_sym.inspect}\n")
        end
        create_file target, rewritten, force: true unless rewritten == source
      end


    end
  end
end
