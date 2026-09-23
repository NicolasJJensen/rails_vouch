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
    controller_class = Class.new(ActionController::Base) do
      include Vouch::Authentication
      auth_scope :user
    end
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
end
