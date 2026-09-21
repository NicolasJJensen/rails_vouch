# frozen_string_literal: true

# Uniform wrapper over one-or-many TwoFactorable has_many associations on an
# account. Lets controllers iterate, scope by `.enabled`, look up by route
# param, or build a new credential without caring how many underlying
# associations there are.
#
# Single-association configs (Account has_many :two_factor_credentials):
#   set = CredentialSet.new(account, [tfc_assoc])
#   set.enabled                  # => CredentialSet (filtered)
#   set.find("3")                # => the credential with id=3
#   set.new(type: "EmailTfc")    # => account.two_factor_credentials.new(...)
#
# Multi-association configs (Account has_many :emails, :phones, :totps where
# each target includes Vouch::TwoFactorable):
#   set = CredentialSet.new(account, [emails_assoc, phones_assoc, totps_assoc])
#   set.enabled                  # => CredentialSet (filtered across all)
#   set.find("phone-2")          # => account.phones.find(2)
#   set.find("3")                # => first match across associations (legacy fallback)
#   set.new(...)                 # => raises (ambiguous; host controllers dispatch by kind)
#
# Route-param format for multi-association configs: "<singular_model>-<id>"
# (e.g. "email-3", "phone-7", "totp-1"). Bare IDs return the first match.
# Multi-association hosts should generate type-prefixed params in their views.
module Vouch
  class CredentialSet
    include Enumerable

    # IDs are opaque route values. In particular, UUIDs contain hyphens, so
    # the kind delimiter is the first hyphen and the remainder belongs to the
    # primary key.
    KIND_ID_FORMAT = /\A(?<kind>[a-z][a-z0-9_]*)-(?<id>[^\/]+)\z/

    def initialize(account, associations, enabled_only: false, filters: [])
      @account       = account
      @associations  = Array(associations)
      @enabled_only  = enabled_only
      @filters       = Array(filters)
    end

    # Filter to credentials with two_factor_enabled_at present. Returns a new
    # CredentialSet so chaining (`.enabled.find(...)`) keeps working.
    def enabled
      self.class.new(@account, @associations, enabled_only: true, filters: @filters)
    end

    # Add a predicate that hides matching credentials from iteration and
    # lookups. Callers pass a block returning true for credentials to hide.
    # Returns a new CredentialSet — chainable and per-request.
    #
    # Used by ControllerHelpers#two_factor_credentials_for to hide the
    # credential the user just used to sign in via magic link.
    def reject(&block)
      raise ArgumentError, "CredentialSet#reject requires a block" unless block_given?

      self.class.new(@account, @associations,
                     enabled_only: @enabled_only,
                     filters:      @filters + [block])
    end

    # Iterate every credential across every association. Required by
    # Enumerable; lets views do `<% @credentials.each do |c| %>`.
    def each
      return enum_for(:each) unless block_given?

      relations.each do |rel|
        rel.each { |record| yield record unless filtered?(record) }
      end
    end

    # Locate a credential by route parameter. Accepts either:
    #   - "<kind>-<id>" (e.g. "phone-3") — preferred for multi-association
    #   - "<id>" — bare-ID lookup across configured associations
    #
    # Raises ActiveRecord::RecordNotFound when no association matches.
    def find(param)
      raise ::ActiveRecord::RecordNotFound, "credential param is blank" if param.to_s.empty?

      if (md = param.to_s.match(KIND_ID_FORMAT))
        matching = associations_for_kind(md[:kind])
        if matching.empty?
          find_by_bare_id!(param)
        else
          find_by_kind!(md[:kind], md[:id], matching)
        end
      else
        find_by_bare_id!(param)
      end
    end

    # Build a new credential. Delegated to the only association when there's
    # one; ambiguous (and raises) when there are several — multi-association
    # hosts override TwoFactorCredentialsController to dispatch on kind.
    def new(*args, **kwargs)
      if @associations.length == 1
        @account.send(@associations.first.name).new(*args, **kwargs)
      else
        raise NoMethodError, <<~MSG.squish
          CredentialSet#new is ambiguous when the account has
          #{@associations.length} TwoFactorable associations. Override
          TwoFactorCredentialsController#new and #create in your host app to
          dispatch on credential kind, or call .new on the underlying
          association directly (e.g. current_account.emails.new(...)).
        MSG
      end
    end

    # Aliases that some Array-shaped callers reach for.
    def to_ary
      to_a
    end

    def empty?
      none?
    end

    def length
      # Delegate to Enumerable#count so filters apply. Costs one iteration.
      count
    end
    alias_method :size, :length

    # Underlying association reflections, in declaration order. Exposed so
    # host controllers and views can introspect the available credential
    # types (e.g. to render a "Choose a 2FA method" picker).
    attr_reader :associations

    private

    def relations
      base = @associations.map { |a| @account.send(a.name) }
      @enabled_only ? base.map(&:enabled) : base
    end

    def find_by_kind!(kind, id, matching = associations_for_kind(kind))
      if matching.empty?
        raise ::ActiveRecord::RecordNotFound,
              "no TwoFactorable association named #{kind.inspect}"
      end
      if matching.length > 1
        raise Vouch::ConfigurationError, <<~MSG.squish
          Credential kind #{kind.inspect} is ambiguous across associations:
          #{matching.map(&:name).join(', ')}. Use a unique model_name.singular
          for each TwoFactorable credential type.
        MSG
      end

      assoc = matching.first
      record = scope_for(assoc).find(id)
      if filtered?(record)
        raise ::ActiveRecord::RecordNotFound,
              "credential #{kind}-#{id} is hidden by the current session filter"
      end
      record
    end

    # Try each association in order. Returns the first match. Multi-association
    # hosts should always use the typed format; this fallback is here so
    # existing single-association integrations keep working untouched.
    def find_by_bare_id!(param)
      @associations.each do |assoc|
        record = scope_for(assoc).find_by(assoc.klass.primary_key => param)
        return record if record && !filtered?(record)
      end
      raise ::ActiveRecord::RecordNotFound,
            "no TwoFactorable credential with id=#{param.inspect}"
    end

    def filtered?(record)
      @filters.any? { |f| f.call(record) }
    end

    def scope_for(assoc)
      base = @account.send(assoc.name)
      @enabled_only ? base.enabled : base
    end

    def singular_for(assoc)
      assoc.klass.model_name.singular
    end

    def associations_for_kind(kind)
      @associations.select { |assoc| singular_for(assoc) == kind }
    end
  end
end
