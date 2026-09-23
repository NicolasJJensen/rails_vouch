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
      @current_mapping = mapping
      @pending_impersonation_mappings = []
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
      end
    end

    def sessions(path_names: {}, controller: nil)
      m = @current_mapping
      ctrl = controller || "#{m.path}/sessions"
      sign_in  = path_names[:sign_in]  || "sign_in"
      sign_out = path_names[:sign_out] || "sign_out"
      prefix = m.helper_prefix

      router.scope m.path do
        router.get    sign_in,  to: "#{ctrl}#new",     as: :"new_#{prefix}_session"
        router.post   sign_in,  to: "#{ctrl}#create",   as: :"#{prefix}_session"
        router.delete sign_out, to: "#{ctrl}#destroy",  as: :"#{prefix}_sign_out"
        if m.split_model? && !m.membership_scope?
          router.get "select", to: "#{m.path}/membership_sessions#new", as: :"#{prefix}_select"
          router.post "select", to: "#{m.path}/membership_sessions#create"
        end
      end
    end

    def registrations(path_names: {}, controller: nil)
      require_credentials_scope!
      m = @current_mapping
      ctrl = controller || "#{m.path}/registrations"
      sign_up = path_names[:sign_up] || "sign_up"
      prefix = m.helper_prefix

      router.scope m.path do
        router.get  sign_up, to: "#{ctrl}#new",    as: :"new_#{prefix}_registration"
        router.post sign_up, to: "#{ctrl}#create",  as: :"#{prefix}_registration"
      end
    end

    def password_resets(controller: nil)
      require_credentials_scope!
      m = @current_mapping
      ctrl = controller || "#{m.path}/password_resets"

      router.scope m.path, as: m.helper_prefix do
        router.resource :password_reset, only: [:new, :create, :edit, :update],
                        controller: ctrl
      end
    end

    def two_factor(challenge_controller: nil, credentials_controller: nil)
      require_credentials_scope!
      m = @current_mapping
      challenge_ctrl = challenge_controller || "#{m.path}/two_factor_challenge"
      creds_ctrl     = credentials_controller || "#{m.path}/two_factor_credentials"

      router.scope m.path, as: m.helper_prefix do
        router.resources :two_factor_challenges, only: [:index, :show, :update],
                         controller: challenge_ctrl do
          router.post :send_code, on: :member
        end
        router.resources :two_factor_credentials, only: [:index, :new, :create, :update, :destroy],
                         controller: creds_ctrl
      end
    end

    def invitations(controller: nil)
      m = @current_mapping
      ctrl = controller || "#{m.path}/invitations"

      router.scope m.path, as: m.helper_prefix do
        router.resource :invitation, only: [:new, :create, :destroy],
                        controller: ctrl do
          router.get :accept, on: :collection
        end
      end
    end

    def impersonation(controller: nil)
      m = @current_mapping
      ctrl = controller || "#{m.path}/impersonations"

      router.scope m.path, as: m.helper_prefix do
        router.post   "impersonations/:id", to: "#{ctrl}#create",      as: :impersonate
        router.delete "impersonations",     to: "#{ctrl}#destroy",      as: :stop_impersonation
        router.delete "impersonations/all", to: "#{ctrl}#destroy_all",  as: :stop_all_impersonations
      end

      @pending_impersonation_mappings << m
    end

    def oauth_callbacks(controller: nil, callback_path: nil, failure_path: nil,
                        callback_methods: nil, failure_methods: nil)
      require_credentials_scope!
      m = @current_mapping
      ctrl = controller || "#{m.path}/omni_auths"

      callback_path ||= m.oauth_callback_path || "/#{m.path}/auth/:provider/callback"
      failure_path  ||= m.oauth_failure_path  || "/#{m.path}/auth/failure"
      callback_methods = Array(callback_methods || m.oauth_callback_methods)
      failure_methods  = Array(failure_methods || m.oauth_failure_methods)

      callback_methods.each do |method|
        add_route(method, callback_path, to: "#{ctrl}#callback")
      end
      failure_methods.each do |method|
        add_route(method, failure_path, to: "#{ctrl}#failure")
      end
    end

    private

    attr_reader :router

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

    def add_route(method, path, to:)
      method = method.to_s.downcase
      unless router.respond_to?(method)
        raise ArgumentError, "Unsupported OAuth route HTTP method: #{method.inspect}"
      end

      router.public_send(method, path, to: to)
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
