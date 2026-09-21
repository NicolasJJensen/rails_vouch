# frozen_string_literal: true

module Vouch
  class Mapping
    # Resolves host-owned Active Record reflections without retaining the
    # reflection objects across reloads. Mapping remains the public contract;
    # this object owns the low-level cardinality and concern scans.
    class ReflectionResolver
      def initialize(mapping)
        @mapping = mapping
      end

      def relationship(owner, macro, target, key, overrides)
        explicit = overrides[key]&.to_sym
        reflections = owner.reflect_on_all_associations(macro).reject(&:polymorphic?)
        if explicit
          reflection = reflections.find { |candidate| candidate.name == explicit }
          unless reflection && reflection.klass == target
            raise ConfigurationError, "#{owner.name} does not have a #{macro} :#{explicit} association targeting #{target.name}"
          end
          return reflection
        end

        matches = reflections.select { |reflection| reflection.klass == target }
        raise ConfigurationError, "#{owner.name} does not have a #{macro} association targeting #{target.name}" if matches.empty?
        if matches.length > 1
          raise ConfigurationError, "#{owner.name} has ambiguous #{key} associations. Set associations: { #{key}: :name }."
        end
        matches.first
      end

      def by_concern(owner, macro, concern_module, explicit_names: nil, feature_flag:, label:)
        if explicit_names
          return Array(explicit_names).map do |name|
            explicit(owner, macro, name, concern_module, label)
          end.then { |resolved| resolved.length == 1 ? resolved.first : resolved.freeze }
        end

        return [].freeze if feature_flag && !@mapping.auth_feature_enabled_for_resolution?(feature_flag)

        reflections = owner.reflect_on_all_associations(macro).select do |reflection|
          begin
            reflection.klass.ancestors.include?(concern_module)
          rescue NameError => e
            raise ConfigurationError, "#{owner.name} has a #{macro} :#{reflection.name} association but the target could not be loaded: #{e.message}"
          end
        end
        reflections
      end

      def oauth_account_association(oauth_identity_association, account_class, account_class_name, explicit: nil)
        oauth_class = oauth_identity_association.klass
        reflections = oauth_class.reflect_on_all_associations(:belongs_to)
        if explicit
          reflection = reflections.find { |candidate| candidate.name == explicit.to_sym }
          unless reflection && oauth_owner_reflection?(reflection, account_class)
            raise ConfigurationError, "#{oauth_class.name} does not have a belongs_to :#{explicit} association that can own #{account_class_name} OAuth identities"
          end
          return reflection
        end

        candidates = reflections.select { |reflection| oauth_owner_reflection?(reflection, account_class) }
        paired = candidates.select { |reflection| oauth_reflections_pair?(oauth_identity_association, reflection) }
        candidates = paired if paired.any?
        raise ConfigurationError, "#{oauth_class.name} does not have a belongs_to association that can own #{account_class_name} OAuth identities. Declare the owner association or set associations: { oauth_account: :name }." if candidates.empty?
        if candidates.length > 1
          raise ConfigurationError, "#{oauth_class.name} has ambiguous oauth_account associations: #{candidates.map(&:name).join(', ')}. Set associations: { oauth_account: :name }."
        end
        candidates.first
      end

      def infer_oauth_account_association(oauth_class, account_class, account_class_name)
        candidates = oauth_class.reflect_on_all_associations(:belongs_to).select do |reflection|
          oauth_owner_reflection?(reflection, account_class)
        end
        return candidates.first if candidates.one?
        names = candidates.map(&:name).join(", ")
        detail = names.present? ? ": #{names}" : ""
        raise ConfigurationError, "#{oauth_class.name} has #{candidates.empty? ? 'no' : 'ambiguous'} oauth_account associations#{detail}. Call resolve_reflections! and set associations: { oauth_account: :name } when an override is required."
      end

      private

      def explicit(owner, macro, name, concern_module, label)
        reflection = owner.reflect_on_all_associations(macro).find { |candidate| candidate.name.to_sym == name.to_sym }
        raise ConfigurationError, "#{owner.name} does not have a #{macro} :#{name} association for #{label}." unless reflection
        begin
          unless reflection.klass.ancestors.include?(concern_module)
            raise ConfigurationError, "#{owner.name} has #{macro} :#{name} that does not target a #{label} model including #{concern_module}."
          end
        rescue NameError => e
          raise ConfigurationError, "#{owner.name} #{macro} :#{name} target could not be loaded: #{e.message}"
        end
        reflection
      end

      def oauth_owner_reflection?(reflection, account_class)
        reflection.polymorphic? || account_class <= reflection.klass
      rescue NameError
        false
      end

      def oauth_reflections_pair?(collection, owner)
        if owner.polymorphic?
          collection.options[:as]&.to_sym == owner.name
        else
          collection.foreign_key.to_s == owner.foreign_key.to_s
        end
      end
    end
  end
end
