require "rails_helper"
require "omniauth"

RSpec.describe "Multiple OAuth registration providers", type: :request do
  around do |example|
    mapping = Vouch.mapping_for(:user)
    previous = mapping.oauth_registration
    mapping.oauth_registration = :form
    example.run
  ensure
    mapping.oauth_registration = previous
  end

  def provider(uid, email: "#{uid}@example.test")
    OmniAuth::AuthHash.new(provider: "example", uid: uid, info: { email: email })
  end

  def connect(uid, email: "#{uid}@example.test", reconnect_uid: nil)
    post "/users/auth/example", params: { purpose: :register, reconnect_uid: reconnect_uid }
    request_params = response.parsed_body
    get "/users/auth/example/callback", env: {
      "omniauth.auth" => provider(uid, email: email), "omniauth.params" => request_params
    }
  end

  def remove_provider(uid)
    Users::RegistrationsController.define_method(:create) do
      result = remove_pending_oauth_identity(provider: params[:provider], uid: params[:uid])
      head(result.ok? ? :no_content : :not_found)
    end
    post "/users/sign_up", params: { provider: "example", uid: uid }
  ensure
    Users::RegistrationsController.remove_method(:create)
  end

  def finish(attributes = { email_address: "finished@example.test" })
    post "/users/sign_up", params: { account: attributes }
  end

  it "saves one account and every independently verified provider" do
    connect("first")
    connect("second")
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("account").email_address).to eq("first@example.test")

    expect { finish }.to change(Account, :count).by(1).and change(OmniAuthIdentity, :count).by(2)
    expect(Account.find_by!(email_address: "finished@example.test").password_digest).to be_nil
  end

  it "does not remap after renders, reconnects or final submission" do
    calls = []
    allow_any_instance_of(Account).to receive(:apply_oauth_registration).and_wrap_original do |method, identity, **options|
      calls << identity.uid
      method.call(identity, **options)
    end
    connect("first")
    finish(email_address: "invalid")
    expect(response).to have_http_status(:unprocessable_entity)
    connect("first", email: "provider-changed@example.test", reconnect_uid: "first")
    get "/users/sign_up"
    expect(controller.view_assigns.fetch("account").email_address).to eq("invalid")
    finish
    expect(calls).to eq(["first"])
  end

  it "requires explicit removal of an expired provider without losing a later proof" do
    connect("first")
    travel Vouch.configuration.pending_authentication_ttl + 1 do
      connect("second")
      expect { finish }.not_to change(Account, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(controller.send(:pending_oauth_providers)).to contain_exactly(
        { provider: "example", uid: "first", expired: true },
        { provider: "example", uid: "second", expired: false }
      )
      remove_provider("first")
      expect { finish }.to change(Account, :count).by(1).and change(OmniAuthIdentity, :count).by(1)
      expect(OmniAuthIdentity.last.uid).to eq("second")
    end
  end

  it "rejects reconnection with a different UID and preserves the selected identity" do
    connect("first")
    connect("second", reconnect_uid: "first")
    expect(flash[:alert]).to include("same provider identity")
    get "/users/sign_up"
    expect(controller.send(:pending_oauth_providers).map { |item| item[:uid] }).to eq(["first"])
  end

  it "requires a real alternative after removing the final provider" do
    connect("first")
    remove_provider("first")
    expect { finish }.not_to change(Account, :count)
    expect(response).to have_http_status(:unprocessable_entity)

    expect { finish(email_address: "password@example.test", password: "password123") }.to change(Account, :count).by(1)
    expect(OmniAuthIdentity.count).to eq(0)
    expect(Account.last.authenticate("password123")).to eq(Account.last)
  end

  it "completes an invited pending owner with two providers and no new tenant" do
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: { token: invitation.invitation_token, choice: "new" }
    connect("first")
    connect("second")
    counts = [Account.count, User.count, Organisation.count]

    expect { finish({}) }.to change(OmniAuthIdentity, :count).by(2)

    expect(response).to redirect_to("/")
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    expect(account.reload.registration_required?).to be(false)
    expect(invitation.reload.invitation_accepted_at).to be_present
    expect(account.omni_auth_identities.pluck(:uid)).to contain_exactly("first", "second")
  end

  it "rolls back every new record when a pending provider becomes owned elsewhere" do
    connect("first")
    connect("second")
    other = create(:account)
    other.omni_auth_identities.create!(provider: "example", uid: "second")
    counts = [Account.count, User.count, Organisation.count, OmniAuthIdentity.count]

    finish

    expect(response).to have_http_status(:unprocessable_entity)
    expect([Account.count, User.count, Organisation.count, OmniAuthIdentity.count]).to eq(counts)
  end

  it "keeps earlier proofs when another provider is already linked" do
    connect("first")
    create(:account).omni_auth_identities.create!(provider: "example", uid: "second")
    connect("second")
    expect(flash[:alert]).to include("already connected")
    get "/users/sign_up"
    expect(controller.send(:pending_oauth_providers).map { |item| item[:uid] }).to eq(["first"])
    expect { finish }.to change(Account, :count).by(1)
  end

  it "refreshes the exact expired provider without remapping profile fields" do
    connect("first")
    travel Vouch.configuration.pending_authentication_ttl + 1 do
      connect("first", email: "new-provider-address@example.test", reconnect_uid: "first")
      get "/users/sign_up"
      expect(controller.view_assigns.fetch("account").email_address).to eq("first@example.test")
      expect(controller.send(:pending_oauth_providers).first[:expired]).to be(false)
      expect { finish }.to change(Account, :count).by(1)
    end
  end

  it "completes an invited owner during automatic OAuth registration" do
    Vouch.mapping_for(:user).oauth_registration = :automatic
    account = create(:account, password: nil, password_confirmation: nil, registration_required: true)
    invitation = create(:user, :invited, account: account, invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: { token: invitation.invitation_token, choice: "new" }
    counts = [Account.count, User.count, Organisation.count]

    connect("first")

    expect(response).to redirect_to("/")
    expect([Account.count, User.count, Organisation.count]).to eq(counts)
    expect(account.reload.registration_required?).to be(false)
    expect(invitation.reload.invitation_accepted_at).to be_present
  end

  it "links multiple providers to the current registered account" do
    user = create(:user)
    sign_in(user)
    %w[first second].each do |uid|
      oauth_callback "/users/auth/example/callback", auth: provider(uid), purpose: :link
      expect(response).to redirect_to("/")
    end
    expect(user.account.omni_auth_identities.pluck(:uid)).to contain_exactly("first", "second")
  end

  it "retains every provider in sign-in hook context through membership selection" do
    original_hooks = [ApplicationController, *ApplicationController.descendants].to_h { |klass| [klass, klass.__hooks] }
    observed = nil
    Users::RegistrationsController.after_oauth_account_creation do |account, _identity|
      FactoryBot.create(:user, account: account)
    end
    ApplicationController.before_sign_in do |_account, _identity, **options|
      observed = options[:auth_hashes]&.map(&:uid)
    end
    connect("first")
    connect("second")
    finish
    expect(response).to redirect_to("/users/select")

    account = Account.find_by!(email_address: "finished@example.test")
    post "/users/select", params: { identity_id: account.users.first.id }

    expect(response).to redirect_to("/")
    expect(observed).to contain_exactly("first", "second")
  ensure
    original_hooks&.each { |klass, hooks| klass.__hooks = hooks }
  end

  it "preserves host identity attributes without changing the verified provider identity" do
    allow_any_instance_of(Account).to receive(:apply_oauth_registration).and_wrap_original do |method, identity, **options|
      method.call(identity, **options)
      identity.provider_nickname = "Custom nickname"
      identity.primary = true
      identity.uid = "unverified-uid"
    end
    connect("first")
    finish

    saved = OmniAuthIdentity.find_by!(provider: "example", uid: "first")
    expect(saved.provider_nickname).to eq("Custom nickname")
    expect(saved.primary).to be(true)
    expect(OmniAuthIdentity.where(uid: "unverified-uid")).not_to exist
  end

  it "preserves prior provider state when a new mapped value exceeds capacity" do
    connect("first")
    allow_any_instance_of(Account).to receive(:apply_oauth_registration).and_wrap_original do |method, identity, **options|
      method.call(identity, **options)
      identity.provider_nickname = "x" * 3_000
    end
    connect("second")
    expect(flash[:alert]).to include("too much provider data")
    get "/users/sign_up"
    expect(controller.send(:pending_oauth_providers).map { |item| item[:uid] }).to eq(["first"])
    expect { finish }.to change(OmniAuthIdentity, :count).by(1)
  end

  it "does not apply existing proofs to a different invitation at final submission" do
    first = create(:user, :invited, account: create(:account, registration_required: true), invitation_sent_at: Time.current)
    second = create(:user, :invited, account: create(:account, registration_required: true), invitation_sent_at: Time.current)
    post "/users/invitation/accept", params: { token: first.invitation_token, choice: "new" }
    connect("first")
    post "/users/invitation/accept", params: { token: second.invitation_token, choice: "new" }

    expect { finish({}) }.not_to change(OmniAuthIdentity, :count)

    expect(response).to redirect_to("/users/sign_in")
    expect(first.reload.invitation_accepted_at).to be_nil
    expect(second.reload.invitation_accepted_at).to be_nil
  end

  it "rejects final submission after the authentication context changed" do
    connect("first")
    Warden.on_next_request do |proxy|
      proxy.raw_session[Vouch::AuthenticationSession::CONTEXT_KEY] = SecureRandom.hex(32)
    end

    expect { finish }.not_to change(OmniAuthIdentity, :count)

    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:alert]).to include("session changed")
  end
end
