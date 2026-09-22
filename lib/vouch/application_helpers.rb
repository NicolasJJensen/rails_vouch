# frozen_string_literal: true

module Vouch
  module ApplicationHelpers
    extend ActiveSupport::Concern

    included do
      Vouch::ApplicationHelpers.register_controller(self)
    end

    class << self
      def register_controller(controller)
        controllers << controller unless controllers.include?(controller)
        expose_helpers(controller, helper_names)
      end

      def define_scope(scope)
        scope = scope.to_sym
        identity_method = :"current_#{scope}"
        account_method = :"current_#{scope}_account"
        signed_in_method = :"#{scope}_signed_in?"

        define_method(identity_method) do
          Vouch.mapping_for(scope)
          request.env.fetch("warden").user(scope)
        end

        define_method(account_method) do
          identity = public_send(identity_method)
          Vouch.mapping_for(scope).account_for(identity) if identity
        end

        define_method(signed_in_method) { public_send(identity_method).present? }

        define_method(:"authenticate_#{scope}!") do
          return if public_send(signed_in_method)

          mapping = Vouch.mapping_for(scope)
          session[Vouch::Session.key_for(scope, :return_to)] = request.fullpath if request.get?
          redirect_to public_send(:"new_#{mapping.helper_prefix}_session_path")
        end

        names = [identity_method, account_method, signed_in_method]
        helper_names.concat(names).uniq!
        controllers.each { |controller| expose_helpers(controller, names) }
      end

      private

      def controllers
        @controllers ||= []
      end

      def helper_names
        @helper_names ||= []
      end

      def expose_helpers(controller, names)
        controller.helper_method(*names) if controller.respond_to?(:helper_method) && names.any?
      end
    end
  end
end
