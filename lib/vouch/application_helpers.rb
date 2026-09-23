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

      def validate_mapping!(mapping)
        names = public_names(mapping)
        Vouch.each_mapping do |other|
          next if other.scope_name == mapping.scope_name
          overlap = names & public_names(other)
          next if overlap.empty?

          raise Vouch::ConfigurationError, "Authentication helpers collide: #{overlap.join(', ')}. Choose distinct scope names."
        end
      end

      def define_scope(_scope)
        refresh!
      end

      def refresh!
        Array(@generated_methods).each { |name| remove_method(name) if instance_methods(false).include?(name) }
        @generated_methods = []
        @helper_names = []
        Vouch.each_mapping { |mapping| install_scope(mapping) }
        controllers.each { |controller| expose_helpers(controller, helper_names) }
      end

      private

      def public_names(mapping)
        names = [mapping.current_helper_name, :"current_#{mapping.scope_name}",
          :"#{mapping.scope_name}_signed_in?", :"authenticate_#{mapping.scope_name}!"].uniq
        names << :"current_#{mapping.scope_name}_#{tenant_name(mapping)}" if mapping.tenant?
        names
      end

      def install_scope(mapping)
        scope = mapping.scope_name
        identity_method = mapping.current_helper_name
        signed_in_method = :"#{scope}_signed_in?"
        define_method(identity_method) { Vouch.authenticated_identity(request.env.fetch("warden"), scope) }
        short_name = :"current_#{scope}"
        alias_method short_name, identity_method unless short_name == identity_method
        define_method(signed_in_method) { public_send(identity_method).present? }
        define_method(:"authenticate_#{scope}!") do
          return if public_send(signed_in_method)

          current_mapping = Vouch.mapping_for(scope)
          session[Vouch::Session.key_for(scope, :return_to)] = request.fullpath if request.get?
          redirect_to public_send(:"new_#{current_mapping.helper_prefix}_session_path")
        end
        @generated_methods.concat(public_names(mapping))
        helper_names.concat([identity_method, short_name, signed_in_method]).uniq!
        install_tenant_helper(mapping, identity_method) if mapping.tenant?
      end

      def tenant_name(mapping)
        mapping.tenant_class_name.underscore.tr("/", "_")
      end

      def install_tenant_helper(mapping, identity_method)
        name = tenant_name(mapping)
        qualified = :"current_#{mapping.scope_name}_#{name}"
        scope = mapping.scope_name
        define_method(qualified) do
          identity = public_send(identity_method)
          identity&.public_send(Vouch.mapping_for(scope).identity_tenant_association.name)
        end
        helper_names << qualified
        mappings = Vouch.each_mapping.to_a
        return unless mappings.count { |candidate| candidate.tenant? && tenant_name(candidate) == name } == 1

        short_name = :"current_#{name}"
        return if mappings.any? { |candidate| public_names(candidate).include?(short_name) }

        alias_method short_name, qualified
        @generated_methods << short_name
        helper_names << short_name
      end

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
