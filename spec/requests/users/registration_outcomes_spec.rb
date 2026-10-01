# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Registration outcomes", type: :request do
  def submit_registration
    post "/users/sign_up", params: { account: {
      email_address: "outcome@example.test", password: "password123", password_confirmation: "password123"
    } }, env: { "action_dispatch.show_exceptions" => :none }
  end

  it "keeps committed records and directs a failed sign-in to sign-in" do
    allow_any_instance_of(Users::RegistrationsController).to receive(:complete_sign_in).and_return(:no_identity)

    expect { submit_registration }.to change(Account, :count).by(1).and change(User, :count).by(1)

    expect(response).to redirect_to("/users/sign_in")
    expect(flash[:notice]).to eq("Account created.")
    expect(flash[:alert]).to eq("Something went wrong signing in, please try again.")
  end

  it "treats required MFA as a continuation" do
    allow_any_instance_of(Users::RegistrationsController).to receive(:complete_sign_in).and_return(:needs_two_factor)

    submit_registration

    expect(response).to redirect_to("/users/two_factor_challenges")
    expect(flash[:alert]).to be_nil
  end

  it "lets a host handle the committed outcome without a second response" do
    Users::RegistrationsController.define_method(:create) do
      super() do |result|
        render json: { status: result.status, committed: result.metadata[:committed], id: result.value.id }
      end
    end

    submit_registration

    expect(response.parsed_body).to include("status" => "ok", "committed" => true)
    expect(response.headers["Location"]).to be_nil
  ensure
    Users::RegistrationsController.remove_method(:create)
  end

  it "renders a useful error when uniqueness changes before insertion" do
    allow_any_instance_of(Account).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

    expect { submit_registration }.not_to change(Account, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(controller.view_assigns.fetch("account").errors[:base]).not_to be_empty
  end

  it "does not rescue an exception raised by the host response block" do
    Users::RegistrationsController.define_method(:create) do
      super() { raise ActiveRecord::RecordInvalid.new(Account.new) }
    end

    submit_registration
    expect(response.body).to include("ActiveRecord::RecordInvalid")
    expect(Account.find_by(email_address: "outcome@example.test")).to be_present
  ensure
    Users::RegistrationsController.remove_method(:create)
  end
end
