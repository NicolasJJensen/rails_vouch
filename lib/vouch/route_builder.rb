# Route DSL for Vouch.
#
# Creates scope mappings and generates named routes for each auth scope.
#
# Select features explicitly; the scope name can be inferred from the identity:
#   Vouch.routes(self) do |auth|
#     auth.scope account: "Account", identity: "User" do
#       auth.sessions
#       auth.registrations
#       auth.password_resets
#     end
#   end
#
module Vouch
  class RouteBuilder
    def initialize(router)
      @router = router
    end

    # Define an authentication scope. Creates the mapping and generates routes.
    #
    # A block is required so optional authentication routes are selected
    # deliberately and the generated host contract remains visible.
    #
    # Split-model:
    #   auth.scope :user, account: "Account", identity: "User"
    #
    # Single-model:
    #   auth.scope :member, model: "Member"
    #
    # With tenant:
    #   auth.scope :user, account: "Account", identity: "User", tenant: "Organisation"
    def scope(scope_name = nil, **opts, &block)
      inferred_scope = scope_name.nil?
      scope_name ||= Vouch::Mapping.inferred_scope_name(
        model: opts[:model], identity: opts[:identity]
      )
      if inferred_scope && scope_name.nil? && (opts[:model] || opts[:identity])
        raise Vouch::ConfigurationError, "Could not infer a valid authentication scope from the supplied model or identity."
      end
      mapping = Vouch::Mapping.new(scope_name, **opts)
      validate_warden_scope_availability!(mapping)
      existing_mapping = Vouch.mappings[scope_name.to_sym]
      if inferred_scope && existing_mapping && !existing_mapping.equivalent_to?(mapping)
        raise Vouch::ConfigurationError, <<~MSG.squish
          Scope :#{scope_name} is already mapped to a different model configuration.
          Supply an explicit, distinct scope name for this mapping.
        MSG
      end
      previous_current_mapping = @current_mapping
      previous_pending_impersonation_mappings = @pending_impersonation_mappings
      previous_pending_memberships = @pending_memberships
      @current_mapping = mapping
      @pending_impersonation_mappings = []
      @pending_memberships = []
      previous_mapping = Vouch.mappings[scope_name.to_sym]
      published = false

      begin
        if block
          block.call(self)
        else
          raise Vouch::ConfigurationError, <<~MSG.squish
            Scope :#{scope_name} requires a route block. Select the baseline
            routes explicitly, for example: auth.sessions; auth.registrations
            then add optional
            feature routes after installing their host model support.
          MSG
        end

        mapping.resolve_reflections!
        Vouch.register_mapping(scope_name, mapping)
        published = true
        register_warden_scope(mapping)
        register_account_scope(mapping) unless mapping.membership_scope?
        @pending_impersonation_mappings.each { |pending| register_impersonation_scope(pending) }
        # Membership mappings need their parent credentials mapping to be
        # registered first.  Deferring them also makes the nested route form
        # an ergonomic spelling of the existing two independent scopes.
        @pending_memberships.each do |membership|
          scope(membership.fetch(:name), **membership.fetch(:options), &membership.fetch(:block))
        end
      rescue StandardError
        if published
          if previous_mapping
            Vouch.mappings[scope_name.to_sym] = previous_mapping
          else
            Vouch.deregister_mapping(scope_name)
          end
        end
        raise
      ensure
        @current_mapping = previous_current_mapping
        @pending_impersonation_mappings = previous_pending_impersonation_mappings
        @pending_memberships = previous_pending_memberships
      end
    end

    # Define a membership authentication scope under the credentials scope
    # currently being configured.  It expands to the same account_scope:
    # mapping accepted by `scope`, while keeping the common route file short.
    def membership(name = nil, model: nil, identity: nil, tenant: nil, **opts, &block)
      parent = @current_mapping
      raise Vouch::ConfigurationError, "auth.membership must appear inside auth.scope." unless parent
      raise Vouch::ConfigurationError, "auth.membership requires a single-model credentials scope." if parent.split_model?
      raise Vouch::ConfigurationError, "auth.membership requires model: or identity:." unless model || identity
      raise Vouch::ConfigurationError, "auth.membership requires a route block." unless block

      if opts.key?(:account_scope) && opts[:account_scope].to_s != parent.scope_name.to_s
        raise Vouch::ConfigurationError, "Nested account_scope must match :#{parent.scope_name}"
      end
      name ||= Vouch::Mapping.inferred_scope_name(model: model, identity: identity)
      @pending_memberships << {
        name: name,
        options: opts.merge(account_scope: parent.scope_name, identity: identity || model, tenant: tenant),
        block: block
      }
    end

    def sessions(paths: {}, path_names: {}, controller: nil)
      m = @current_mapping
      ctrl = controller || "#{m.scope_name.to_s.pluralize}/sessions"
      routes = {new: "sign_in", create: "sign_in", destroy: "sign_out", confirmation: "confirmation", confirm: "confirmation", cancel_confirmation: "confirmation"}.merge(validate_paths!(:sessions, paths))
      m.configure_route_names(:sessions, path_names)
      prefix = m.helper_prefix

      router.scope m.path do
        router.get routes[:new], to: "#{ctrl}#new", as: m.route_name(:sessions, :new)
        router.post routes[:create], to: "#{ctrl}#create", as: m.route_name(:sessions, :create)
        router.delete routes[:destroy], to: "#{ctrl}#destroy", as: m.route_name(:sessions, :destroy)
        unless m.membership_scope?
          router.get routes[:confirmation], to: "#{ctrl}#confirmation", as: m.route_name(:sessions, :confirmation)
          router.post routes[:confirm], to: "#{ctrl}#confirm", as: m.route_name(:sessions, :confirm)
          router.delete routes[:cancel_confirmation], to: "#{ctrl}#cancel_confirmation", as: m.route_name(:sessions, :cancel_confirmation)
        end
        if m.split_model? && !m.membership_scope?
          router.get "select", to: "#{m.scope_name.to_s.pluralize}/membership_sessions#new", as: :"#{prefix}_select"
          router.post "select", to: "#{m.scope_name.to_s.pluralize}/membership_sessions#create"
        end
      end
    end

    def registrations(paths: {}, path_names: {}, controller: nil)
      require_credentials_scope!
      m = @current_mapping
      ctrl = controller || "#{m.scope_name.to_s.pluralize}/registrations"
      routes = {new: "sign_up", create: "sign_up"}.merge(validate_paths!(:registrations, paths))
      m.configure_route_names(:registrations, path_names)

      router.scope m.path do
        router.get routes[:new], to: "#{ctrl}#new", as: m.route_name(:registrations, :new)
        router.post routes[:create], to: "#{ctrl}#create", as: m.route_name(:registrations, :create)
      end
    end

    def password_resets(controller: nil, paths: {}, path_names: {})
      require_credentials_scope!
      draw_feature_routes(:password_resets, controller, paths, path_names, {
        new: [[:get], "password_reset/new"],
        create: [[:post], "password_reset"],
        edit: [[:get], "password_reset/edit"],
        update: [[:patch, :put], "password_reset"]
      })
    end

    def two_factor_challenges(controller: nil, paths: {}, path_names: {})
      require_credentials_scope!
      controller ||= "#{@current_mapping.scope_name.to_s.pluralize}/two_factor_challenge"
      draw_feature_routes(:two_factor_challenges, controller, paths, path_names, {
        index: [[:get], "two_factor_challenges"],
        show: [[:get], "two_factor_challenges/:id"],
        update: [[:patch, :put], "two_factor_challenges/:id"],
        send_code: [[:post], "two_factor_challenges/:id/send_code"],
        destroy: [[:delete], "two_factor_challenges"],
        recovery: [[:get], "recovery"],
        consume_recovery: [[:post], "recovery"]
      })
    end

    def two_factor_credentials(controller: nil, paths: {}, path_names: {})
      require_credentials_scope!
      draw_feature_routes(:two_factor_credentials, controller, paths, path_names, {
        index: [[:get], "two_factor_credentials"],
        new: [[:get], "two_factor_credentials/new"],
        create: [[:post], "two_factor_credentials"],
        edit: [[:get], "two_factor_credentials/:id/edit"],
        send_code: [[:post], "two_factor_credentials/:id/send_code"],
        update: [[:patch, :put], "two_factor_credentials/:id"],
        destroy: [[:delete], "two_factor_credentials/:id"]
      })
    end

    def recovery_codes(controller: nil, paths: {}, path_names: {})
      require_credentials_scope!
      draw_feature_routes(:recovery_codes, controller, paths, path_names, {
        show: [[:get], "recovery_codes"],
        create: [[:post], "recovery_codes"]
      })
    end

    def invitations(controller: nil, paths: {}, path_names: {})
      draw_feature_routes(:invitations, controller, paths, path_names, {
        new: [[:get], "invitation/new"],
        create: [[:post], "invitation"],
        destroy: [[:delete], "invitation"],
        accept: [[:get, :post], "invitation/accept"],
        reject: [[:post], "invitation/reject"],
        resend: [[:post], "invitation/resend"]
      })
    end

    def impersonation(controller: nil, paths: {}, path_names: {})
      controller ||= "#{@current_mapping.scope_name.to_s.pluralize}/impersonations"
      draw_feature_routes(:impersonation, controller, paths, path_names, {
        create: [[:post], "impersonations/:id"],
        destroy: [[:delete], "impersonations"],
        destroy_all: [[:delete], "impersonations/all"]
      })
      @pending_impersonation_mappings << @current_mapping
    end

    def oauth_callbacks(controller: nil, callback_path: nil, failure_path: nil,
                        callback_methods: nil, failure_methods: nil, registration: :form, paths: {}, path_names: {})
      require_credentials_scope!
      m = @current_mapping
      ctrl = controller || "#{m.scope_name.to_s.pluralize}/omni_auths"
      unless %i[form automatic].include?(registration)
        raise Vouch::ConfigurationError, "OAuth registration must be :form or :automatic"
      end
      m.oauth_registration = registration
      overrides = validate_paths!(:oauth_callbacks, paths)
      m.configure_route_names(:oauth_callbacks, path_names)
      callback_path = overrides[:callback] if overrides.key?(:callback)
      failure_path = overrides[:failure] if overrides.key?(:failure)

      callback_path ||= m.oauth_callback_path || "/#{m.path}/auth/:provider/callback"
      m.oauth_callback_path = callback_path
      m.oauth_callbacks_enabled = true
      failure_path  ||= m.oauth_failure_path  || "/#{m.path}/auth/failure"
      callback_methods = Array(callback_methods || m.oauth_callback_methods)
      failure_methods  = Array(failure_methods || m.oauth_failure_methods)

      callback_methods.each_with_index do |method, index|
        add_route(method, callback_path, to: "#{ctrl}#callback", as: (m.route_name(:oauth_callbacks, :callback) if index.zero?))
      end
      failure_methods.each_with_index do |method, index|
        add_route(method, failure_path, to: "#{ctrl}#failure", as: (m.route_name(:oauth_callbacks, :failure) if index.zero?))
      end
    end

    private

    attr_reader :router

    def draw_feature_routes(feature, controller, paths, path_names, definitions)
      mapping = @current_mapping
      overrides = validate_paths!(feature, paths)
      mapping.configure_route_names(feature, path_names)
      controller ||= "#{mapping.scope_name.to_s.pluralize}/#{feature}"
      helpers = {}
      router.scope mapping.path do
        definitions.each do |action, (methods, default_path)|
          path = overrides.fetch(action, default_path)
          name = mapping.route_name(feature, action)
          if helpers.key?(name) && helpers[name] != path
            raise Vouch::ConfigurationError, "#{feature} actions sharing #{name.inspect} need the same path or distinct path_names"
          end
          router.match path, via: methods, to: "#{controller}##{action}", as: (name unless helpers.key?(name))
          helpers[name] = path
        end
      end
    end

    def validate_paths!(feature, paths)
      allowed = @current_mapping.default_route_names.fetch(feature).keys
      values = paths.transform_keys(&:to_sym)
      unknown = values.keys - allowed
      raise Vouch::ConfigurationError, "Unknown #{feature} paths: #{unknown.join(', ')}" if unknown.any?
      values
    end

    def require_credentials_scope!
      return unless @current_mapping.membership_scope?

      raise Vouch::ConfigurationError, "Configure credential routes on :#{@current_mapping.parent_scope_name}, not membership scope :#{@current_mapping.scope_name}."
    end

    # Use the same revocation contract for established and pending sessions.
    def register_warden_scope(mapping)
      scope          = mapping.scope_name
      fingerprinter  = method(:session_fingerprint)

      Warden::Manager.serialize_into_session(scope) do |identity|
        account = mapping.account_for(identity)
        [Vouch::RecordKey.value(identity), fingerprinter.call(account)]
      end

      Warden::Manager.serialize_from_session(scope) do |payload|
        id, fingerprint = Array(payload)
        identity_class = mapping.identity_class
        identity = begin
          Vouch::RecordKey.find(identity_class, id)
        rescue ActiveRecord::RecordNotFound, ArgumentError
          nil
        end
        next nil unless identity

        account = mapping.account_for(identity)
        next nil unless account
        next nil if Vouch.configuration.lockable.invalidate_sessions_on_lockout &&
          account.respond_to?(:locked?) && account.locked?

        current = fingerprinter.call(account)
        next nil unless ActiveSupport::SecurityUtils.secure_compare(
          fingerprint.to_s, current.to_s
        )
        impersonation_session = env["warden"]&.raw_session
        if impersonation_session && Vouch::ImpersonationStack.active?(impersonation_session) &&
            (mapping.split_model? || Vouch::ImpersonationStack.target_scope(impersonation_session) == scope)
          next Vouch::ImpersonationStack.authorized_identity(impersonation_session, scope: scope, identity: identity)
        end
        if mapping.membership_scope?
          parent = env["warden"]&.user(mapping.parent_scope_name)
          next nil unless parent && parent.class == account.class &&
            Vouch::RecordKey.same?(parent, account, model: account.class)
        end

        identity
      end
    end

    # Resolve current model classes on every restoration so reloads do not
    # retain references to stale Active Record classes.
    def register_account_scope(mapping)
      account_scope = mapping.account_scope_name
      fingerprinter = method(:session_fingerprint)

      Warden::Manager.serialize_into_session(account_scope) do |account|
        [Vouch::RecordKey.value(account), fingerprinter.call(account)]
      end

      Warden::Manager.serialize_from_session(account_scope) do |payload|
        id, fingerprint = Array(payload)
        account_class = mapping.account_class
        account = begin
          Vouch::RecordKey.find(account_class, id)
        rescue ActiveRecord::RecordNotFound, ArgumentError
          nil
        end
        next nil unless account
        next nil if Vouch.configuration.lockable.invalidate_sessions_on_lockout &&
          account.respond_to?(:locked?) && account.locked?

        current = fingerprinter.call(account)
        next nil unless ActiveSupport::SecurityUtils.secure_compare(
          fingerprint.to_s, current.to_s
        )

        account
      end
    end

    # Restoration proves the original operator's session, independently of
    # the target's credentials. Rotating the operator's password revokes it.
    def register_impersonation_scope(mapping)
      impersonation_scope = :"#{mapping.scope_name}_impersonation"
      fingerprinter = method(:session_fingerprint)

      Warden::Manager.serialize_into_session(impersonation_scope) do |identity|
        [Vouch::RecordKey.value(identity), fingerprinter.call(mapping.account_for(identity))]
      end

      Warden::Manager.serialize_from_session(impersonation_scope) do |payload|
        id, fingerprint = Array(payload)
        identity_class = mapping.identity_class
        identity = begin
          Vouch::RecordKey.find(identity_class, id)
        rescue ActiveRecord::RecordNotFound, ArgumentError
          nil
        end
        next nil unless identity

        account = mapping.account_for(identity)
        next nil unless account && !account.locked?
        next nil unless ActiveSupport::SecurityUtils.secure_compare(
          fingerprint.to_s, fingerprinter.call(account).to_s
        )

        identity
      end
    end

    def add_route(method, path, to:, as: nil)
      method = method.to_s.downcase
      unless router.respond_to?(method)
        raise ArgumentError, "Unsupported OAuth route HTTP method: #{method.inspect}"
      end

      router.public_send(method, path, to: to, as: as)
    end

    def session_fingerprint(account)
      Vouch::PendingAuthentication.fingerprint(account)
    end

    def validate_warden_scope_availability!(mapping)
      reserved = Vouch.reserved_warden_scopes_for(mapping.scope_name)
      conflicts = Vouch.each_mapping.filter_map do |existing|
        next if existing.scope_name == mapping.scope_name

        overlap = reserved & Vouch.reserved_warden_scopes_for(existing.scope_name)
        [existing, overlap] if overlap.any?
      end
      return if conflicts.empty?

      details = conflicts.map do |existing, overlap|
        ":#{existing.scope_name} (#{overlap.map { |scope| ":#{scope}" }.join(', ')})"
      end.join('; ')
      raise Vouch::ConfigurationError, <<~MSG.squish
        Scope :#{mapping.scope_name} reserves Warden scope(s) already reserved by
        #{details}. Choose a scope name that does not overlap another Vouch mapping.
      MSG
    end
  end
end
