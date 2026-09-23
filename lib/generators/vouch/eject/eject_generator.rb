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
    #   bin/rails g vouch:eject admins passwords
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
        "passwords"              => "PasswordsController",
        "invitations"            => "InvitationsController",
        "two_factor_challenge"   => "TwoFactorChallengeController",
        "two_factor_credentials" => "TwoFactorCredentialsController",
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
        body   = rewrite_class_declaration(File.read(source_path))
        body   = add_auth_scope(body) if options[:auth_scope].present?
        target = "app/controllers/#{scope}/#{controller_name}_controller.rb"

        create_file target, body
      end

      private

      def source_path
        gem_root = Gem.loaded_specs["rails_vouch"]&.full_gem_path ||
                   File.expand_path("../../../..", __dir__)

        File.join(gem_root, "app/controllers/vouch/#{controller_name}_controller.rb")
      end

      def rewrite_class_declaration(body)
        class_name = CONTROLLERS.fetch(controller_name)
        body.sub(
          "class Vouch::#{class_name}",
          "class #{scope.camelize}::#{class_name}"
        )
      end

      def add_auth_scope(body)
        body.sub(
          /^(class .*\n)/,
          "\\1  auth_scope #{options[:auth_scope].to_sym.inspect}\n"
        )
      end

    end
  end
end
