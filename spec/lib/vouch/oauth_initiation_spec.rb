# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::OAuthInitiation do
  let(:mapping) { Vouch.mapping_for(:user) }
  let(:app) { ->(_env) { [204, {}, []] } }

  def call(path, referer: nil, session: {})
    env = Rack::MockRequest.env_for(path, method: "POST", "HTTP_REFERER" => referer)
    env["rack.session"] = session
    described_class.new(app).call(env)
    session
  end

  it "captures a same-origin initiation referer in the matching scope" do
    session = call("/users/auth/google_oauth2", referer: "http://example.org/projects?tab=access")

    expect(session[described_class.return_to_key(:user)]).to eq("/projects?tab=access")
  end

  it "rejects an external referer and clears an older return path" do
    key = described_class.return_to_key(:user)
    session = call("/users/auth/google_oauth2", referer: "https://example.test/projects", session: {key => "/older"})

    expect(session).not_to have_key(key)
  end

  it "does not capture a callback or failure request" do
    key = described_class.return_to_key(:user)

    callback_session = call("/users/auth/google_oauth2/callback", referer: "http://example.org/projects", session: {key => "/older"})
    failure_session = call("/users/auth/failure", referer: "http://example.org/projects", session: {key => "/older"})

    expect(callback_session[key]).to eq("/older")
    expect(failure_session[key]).to eq("/older")
  end

  it "is absent from a Rails middleware stack without OmniAuth" do
    stack = Rails.application.middleware
    middleware = stack.map(&:klass)

    expect(middleware).not_to include(OmniAuth::Builder)
    expect(middleware).not_to include(described_class)
  end
end
