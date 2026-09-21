# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Warden host interoperability" do
  it "preserves a serialized host scope through a real Vouch sign-in" do
    callbacks = Warden::Manager._after_set_user.dup
    configured_managers = Vouch.configured_warden_configs.dup
    serializer_methods = Warden::SessionSerializer.instance_methods(false)
    host_identity = create(:user)
    auth_identity = create(:user)
    events = []
    observed = {}

    Warden::Manager.serialize_into_session(:host_admin_contract) { |identity| identity.id }
    Warden::Manager.serialize_from_session(:host_admin_contract) { |id| User.find_by(id: id) }
    Warden::Manager.after_authentication do |record, _proxy, options|
      events << [record.id, options.fetch(:scope)]
    end

    controller_class = Class.new(Vouch::BaseController) { auth_scope :user }
    app = lambda do |env|
      proxy = env.fetch("warden")
      case env.fetch("PATH_INFO")
      when "/host-login"
        proxy.set_user(host_identity, scope: :host_admin_contract, store: true, event: :authentication)
      when "/vouch-sign-in"
        controller = controller_class.new
        controller.define_singleton_method(:session) { proxy.raw_session }
        controller.define_singleton_method(:warden) { proxy }
        controller.define_singleton_method(:reset_session) { proxy.raw_session.clear }
        observed[:result] = controller.send(:complete_sign_in, auth_identity.account)
      when "/restored-session"
        observed[:host] = proxy.user(:host_admin_contract)
        observed[:auth] = proxy.user(:user)
      end
      [200, { "content-type" => "text/plain" }, ["ok"]]
    end
    manager = Warden::Manager.new(app) do |config|
      config.default_scope = :host_admin_contract
      config.default_strategies(:host_strategy)
    end
    allow(Vouch.configuration).to receive(:preserved_auth_scopes).and_return([:host_admin_contract])
    Vouch.configure_warden(manager)

    session = {}
    call = lambda do |path|
      env = Rack::MockRequest.env_for(path)
      env["rack.session"] = session
      manager.call(env)
    end
    call.call("/host-login")
    call.call("/vouch-sign-in")
    call.call("/restored-session")

    expect(observed[:result]).to eq(:signed_in)
    expect(observed[:host]).to eq(host_identity)
    expect(observed[:auth]).to eq(auth_identity)
    expect(events).to include([host_identity.id, :host_admin_contract], [auth_identity.id, :user])
    expect(manager.config.default_scope).to eq(:host_admin_contract)
    expect(manager.config.default_strategies).to eq([:host_strategy])
    expect(manager.config.default_strategies(scope: :user)).to eq([:password])
  ensure
    Warden::Manager._after_set_user.replace(callbacks) if callbacks
    Vouch.configured_warden_configs.replace(configured_managers) if configured_managers
    if serializer_methods
      added = Warden::SessionSerializer.instance_methods(false) - serializer_methods
      added.each { |method| Warden::SessionSerializer.send(:remove_method, method) }
    end
  end

  it "skips a configured host authentication callback only on public auth actions" do
    allow(Vouch.configuration).to receive(:authentication_callbacks).and_return([:host_authentication])
    controller_class = Class.new(Vouch::BaseController) do
      attr_reader :host_callback_ran

      before_action :host_authentication
      allow_unauthenticated_access only: :public_action

      def public_action
        head :ok
      end

      def protected_action
        head :ok
      end

      private

      def host_authentication
        @host_callback_ran = true
      end
    end

    public_controller = controller_class.new
    public_controller.set_request!(ActionDispatch::TestRequest.create)
    public_controller.set_response!(ActionDispatch::TestResponse.new)
    public_controller.process(:public_action)

    protected_controller = controller_class.new
    protected_controller.define_singleton_method(:current_identity) { Object.new }
    protected_controller.set_request!(ActionDispatch::TestRequest.create)
    protected_controller.set_response!(ActionDispatch::TestResponse.new)
    protected_controller.process(:protected_action)

    expect(public_controller.host_callback_ran).to be_nil
    expect(protected_controller.host_callback_ran).to be(true)
  end
end
