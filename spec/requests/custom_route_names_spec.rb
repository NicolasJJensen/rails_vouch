# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Custom authentication route names", type: :request do
  before do
    @mappings = Vouch.mappings.dup
    stub_const("Portal", Module.new)
    stub_const("Portal::SessionsController", Class.new(Vouch::SessionsController) do
      auth_scope :account
      def new
        render inline: '<%= form_with url: vouch_route_path(:sessions, :create) do %><%= link_to "Register", vouch_route_path(:registrations, :new) %><% end %>'
      end
    end)
    stub_const("Portal::RegistrationsController", Class.new(Vouch::RegistrationsController) do
      auth_scope :account
    end)
    stub_const("Portal::PagesController", Class.new(ApplicationController) do
      before_action :authenticate_account!
      def show
        render plain: current_account.email_address
      end
    end)
    Rails.application.routes.draw do
      Vouch.routes(self) do |auth|
        auth.scope model: "Account", path: "portal" do
          auth.sessions controller: "portal/sessions",
            paths: {new: "login", create: "login", destroy: "logout"},
            path_names: {new: :sign_in, create: :create_session, destroy: :sign_out}
          auth.registrations controller: "portal/registrations",
            paths: {new: "join", create: "join"},
            path_names: {new: :sign_up, create: :register}
        end
      end
      get "/protected", to: "portal/pages#show"
      root "rails/health#show"
    end
  end

  after do
    Vouch.mappings.replace(@mappings)
    Vouch::ApplicationHelpers.refresh!
    Rails.application.reload_routes!
  end

  it "uses the configured names in guards, forms, login and logout" do
    routes = Rails.application.routes.url_helpers
    expect(routes.sign_in_path).to eq("/portal/login")
    expect(routes.create_session_path).to eq("/portal/login")
    expect(routes.sign_up_path).to eq("/portal/join")
    expect(routes).not_to respond_to(:new_account_session_path)
    get "/protected"
    expect(response).to redirect_to("/portal/login")
    get "/portal/login"
    expect(response.body).to include('action="/portal/login"', 'href="/portal/join"')
    account = create(:account, password: "password123", password_confirmation: "password123")
    post "/portal/login", params: {email_address: account.email_address, password: "password123"}
    expect(response).to redirect_to("/protected")
    get "/protected"
    expect(response.body).to eq(account.email_address)
    delete "/portal/logout"
    expect(response).to redirect_to("/portal/login")
  end

  it "uses custom helpers in the Warden failure destination" do
    mapping = Vouch.mapping_for(:account)
    expect(mapping.failure_path_for(nil, Rails.application.routes.url_helpers)).to eq("/portal/login")
  end
end
