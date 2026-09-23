# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::Redirects, type: :controller do
  controller(ApplicationController) do
    include Vouch::Authentication
    auth_scope :user

    def index
      head :ok
    end
  end

  before do
    routes.draw do
      root to: "anonymous#index"
      get "users/sign_in", to: "anonymous#index", as: :new_user_session
    end
  end

  it "defaults sign-in and sign-up redirects to the application root" do
    expect(controller.send(:after_sign_in_path_for, create(:user), scope: :user)).to eq("/")
    expect(controller.send(:after_sign_up_path_for, create(:user), scope: :user)).to eq("/")
  end

  it "defaults sign-out redirects to the scoped session route" do
    expect(controller.send(:after_sign_out_path_for, scope: :user)).to eq("/users/sign_in")
  end

  it "allows an application controller override to win" do
    controller.define_singleton_method(:after_sign_in_path_for) { |_identity = nil, scope: nil| "/dashboard" }

    expect(controller.send(:after_sign_in_path_for, create(:user), scope: :user)).to eq("/dashboard")
  end

  it "keeps the endpoint helpers as delegates to the shared redirect hooks" do
    identity = instance_double(User)
    allow(controller).to receive(:current_identity).and_return(identity)
    expect(controller).to receive(:after_sign_in_path_for).with(identity, scope: :user).and_return("/signed-in")
    expect(controller).to receive(:after_sign_up_path_for).with(identity, scope: :user).and_return("/signed-up")
    expect(controller).to receive(:after_sign_out_path_for).with(scope: :user).and_return("/signed-out")

    expect(controller.send(:after_sign_in_path)).to eq("/signed-in")
    expect(controller.send(:after_sign_up_path)).to eq("/signed-up")
    expect(controller.send(:after_sign_out_path)).to eq("/signed-out")
  end
end
