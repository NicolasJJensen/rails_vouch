# frozen_string_literal: true

require "rails_helper"

RSpec.describe "namespaced account form parameters", type: :request do
  it "uses the same parameter key as a real Rails model form" do
    stub_const("Backoffice", Module.new)
    stub_const("Backoffice::Credential", Class.new(Account))
    mapping = Vouch::Mapping.new(
      :backoffice_user,
      model: "Backoffice::Credential"
    )
    rendered_form = ApplicationController.render(
      inline: <<~ERB,
        <%= form_with model: account, url: "/backoffice/sign_up" do |form| %>
          <%= form.email_field :email_address %>
        <% end %>
      ERB
      locals: { account: Backoffice::Credential.new }
    )
    form_param_key = rendered_form[/name="([^"]+)\[email_address\]"/, 1]

    expect(form_param_key).to eq(Backoffice::Credential.model_name.param_key)
    expect(mapping.account_param_key).to eq(form_param_key.to_sym)
  end

  it "honours a host model's custom form parameter key" do
    stub_const("CustomFormAccount", Class.new(Account) do
      def self.model_name
        ActiveModel::Name.new(self, nil, "Registration")
      end
    end)
    mapping = Vouch::Mapping.new(:custom_form, model: "CustomFormAccount")
    rendered_form = ApplicationController.render(
      inline: <<~ERB,
        <%= form_with model: account, url: "/custom/sign_up" do |form| %>
          <%= form.password_field :password %>
        <% end %>
      ERB
      locals: { account: CustomFormAccount.new }
    )
    form_param_key = rendered_form[/name="([^"]+)\[password\]"/, 1]

    expect(form_param_key).to eq("registration")
    expect(mapping.account_param_key).to eq(form_param_key.to_sym)
  end
end
