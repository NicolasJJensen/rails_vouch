# frozen_string_literal: true

module Vouch
  module RecoveryCodeAssociation
    extend ActiveSupport::Concern

    included do
      class_attribute :recovery_code_association_name, instance_writer: false
    end

    class_methods do
      def recovery_codes_from(name)
        self.recovery_code_association_name = name.to_sym
      end
    end

    private

    def configured_recovery_codes(default:)
      name = self.class.recovery_code_association_name || default
      reflection = self.class.reflect_on_association(name)
      unless reflection&.macro == :has_many && !reflection.options[:through]
        raise Vouch::ConfigurationError, "#{self.class.name}.recovery_codes_from :#{name} must name a direct has_many association"
      end
      missing = %w[code_digest used_at] - reflection.klass.column_names
      if missing.any?
        raise Vouch::ConfigurationError, "#{reflection.klass.name} needs recovery code columns: #{missing.join(', ')}"
      end
      public_send(name)
    end
  end
end
