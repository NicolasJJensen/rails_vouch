# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::FailureApp do
  describe ".call" do
    it "is a Rack app" do
      expect(described_class).to respond_to(:call)
    end
  end

  describe "#respond" do
    let(:mapping) do
      Vouch::Mapping.new(:user, account: "Account", identity: "User", tenant: "Organisation")
    end

    let(:app) { described_class.new }
    let(:flash) { {} }

    before do
      unless described_class.instance_variable_get(:@_routes_included)
        described_class.include Rails.application.routes.url_helpers
        described_class.instance_variable_set(:@_routes_included, true)
      end

      allow(app).to receive(:warden_options).and_return({ scope: :user })
      allow(Vouch).to receive(:mapping_for).with(:user).and_return(mapping)
      allow(app).to receive(:new_user_session_path).and_return("/users/sign_in")
      allow(app).to receive(:flash).and_return(flash)
      allow(app).to receive(:redirect_to)
    end

    it "redirects to the scope's sign-in path" do
      expect(app).to receive(:redirect_to).with("/users/sign_in")
      app.respond
    end

    context "when no warden message is present" do
      before { allow(app).to receive(:warden_message).and_return(nil) }

      it "sets the default flash alert" do
        app.respond
        expect(flash[:alert]).to eq("You need to sign in.")
      end
    end

    context "when a custom warden message is present" do
      before { allow(app).to receive(:warden_message).and_return("Account is locked.") }

      it "uses the custom message as the flash alert" do
        app.respond
        expect(flash[:alert]).to eq("Account is locked.")
      end
    end

    context "when no scope is given" do
      before do
        allow(app).to receive(:warden_options).and_return({})
        allow(Vouch).to receive(:mappings).and_return({ user: mapping })
      end

      it "falls back to the first mapping" do
        expect(app).to receive(:redirect_to).with("/users/sign_in")
        app.respond
      end
    end
  end

end
