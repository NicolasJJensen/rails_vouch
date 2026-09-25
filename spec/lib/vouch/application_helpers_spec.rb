# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::ApplicationHelpers, type: :controller do
  controller(ApplicationController) do
    before_action :authenticate_user!, except: :public_page

    def index
    render inline: '<%= current_user.id %>:<%= current_user.account.id %>:<%= user_signed_in? %>'
    end

    def public_page
      render plain: "public"
    end
  end

  let(:proxy) { instance_double(Warden::Proxy) }
  let(:identity) { create(:user) }

  before do
    routes.draw do
      get "index", to: "anonymous#index"
      post "index", to: "anonymous#index"
      get "public_page", to: "anonymous#public_page"
      get "users/sign_in", to: "users/sessions#new", as: :new_user_session
    end
    request.env["warden"] = proxy
    allow(proxy).to receive(:user).with(:user).and_return(nil)
  end

  it "makes authentication opt-in on ordinary application controllers" do
    get :public_page
    expect(response.body).to eq("public")
    expect(controller.respond_to?(:complete_sign_in, true)).to be(false)
    expect(controller.respond_to?(:build_registration, true)).to be(false)
  end

  it "redirects anonymous GETs and preserves the destination" do
    get :index, params: { page: "2" }
    expect(response).to redirect_to("/users/sign_in")
    expect(session[Vouch::Session.key_for(:user, :return_to)]).to eq(request.fullpath)
  end

  it "does not save a POST as the return destination" do
    post :index
    expect(response).to redirect_to("/users/sign_in")
    expect(session[Vouch::Session.key_for(:user, :return_to)]).to be_nil
  end

  it "exposes the completed identity and its account in views" do
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    get :index
    expect(response.body).to eq("#{identity.id}:#{identity.account.id}:true")
  end

  it "does not treat a pending account or MFA state as signed in" do
    session[Vouch::Session.key_for(:user, :two_factor)] = { "account_id" => identity.account.id }
    expect(controller.current_user).to be_nil
    expect(controller.user_signed_in?).to be(false)
    get :index
    expect(response).to redirect_to("/users/sign_in")
  end

  it "returns the authenticated identity from the current scope" do
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    expect(controller.current_user).to eq(identity)
  end

  it "exposes the effective user as the true user outside impersonation" do
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    expect(controller.true_user).to eq(identity)
    expect(controller.impersonating_user?).to be(false)
    expect(controller.class._helper_methods).to include(:true_user, :impersonating_user?)
  end

  it "does not present the target as the original actor for another source scope" do
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    session[Vouch::ImpersonationStack::SESSION_KEY] = [{"source_scope" => "admin", "target_scope" => "user"}]
    expect(controller.true_user).to be_nil
    expect(controller.impersonating_user?).to be(true)
  end

  it "keeps separate scopes independent, including when they share model classes" do
    original = Vouch.mappings[:customer]
    mapping = Vouch::Mapping.new(:customer, account: "Account", identity: "User", tenant: "Organisation")
    mapping.resolve_reflections!
    Vouch.register_mapping(:customer, mapping)
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    allow(proxy).to receive(:user).with(:customer).and_return(nil)

    expect(controller.user_signed_in?).to be(true)
    expect(controller.customer_signed_in?).to be(false)
    expect(controller.class._helper_methods).to include(:current_customer, :customer_signed_in?)
  ensure
    original ? Vouch.mappings[:customer] = original : Vouch.deregister_mapping(:customer)
  end

  it "respects overridden route helper prefixes" do
    mapping = Vouch.mapping_for(:user).dup
    allow(mapping).to receive(:helper_prefix).and_return(:portal)
    allow(Vouch).to receive(:mapping_for).with(:user).and_return(mapping)
    routes.draw do
      get "index", to: "anonymous#index"
      get "portal/login", to: "users/sessions#new", as: :new_portal_session
    end
    controller.singleton_class.include(routes.url_helpers)
    get :index
    expect(response).to redirect_to("/portal/login")
  end

  it "returns the same record for a single-model identity and account" do
    original = Vouch.mappings[:member]
    mapping = Vouch::Mapping.new(:member, model: "Account")
    mapping.resolve_reflections!
    Vouch.register_mapping(:member, mapping)
    account = identity.account
    allow(proxy).to receive(:user).with(:member).and_return(account)

    expect(controller.current_member).to eq(account)
  ensure
    original ? Vouch.mappings[:member] = original : Vouch.deregister_mapping(:member)
  end

  it "exposes the named tenant through the authenticated membership" do
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    expect(controller.current_organisation).to eq(identity.organisation)
    expect(controller).not_to respond_to(:current_tenant)
    expect(controller.class._helper_methods).to include(:current_organisation)
    allow(proxy).to receive(:user).with(:user).and_return(nil)
    expect(controller.current_organisation).to be_nil
  end

  it "qualifies tenant helpers when multiple scopes can select different tenants" do
    mapping = Vouch::Mapping.new(:customer, account: "Account", identity: "User", tenant: "Organisation")
    mapping.resolve_reflections!
    Vouch.register_mapping(:customer, mapping)
    allow(proxy).to receive(:user).with(:user).and_return(identity)
    allow(proxy).to receive(:user).with(:customer).and_return(nil)
    expect(controller).not_to respond_to(:current_organisation)
    expect(controller.current_user_organisation).to eq(identity.organisation)
    expect(controller.current_customer_organisation).to be_nil
  ensure
    Vouch.deregister_mapping(:customer)
  end

  it "also installs the small helper module on API controllers" do
    expect(ActionController::API.ancestors).to include(Vouch::ApplicationHelpers)
    expect(ActionController::API.new).to respond_to(:authenticate_user!, :current_user)
  end
end
