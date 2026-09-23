# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "tmpdir"
require "fileutils"
require "generators/vouch/two_factorable/two_factorable_generator"

RSpec.describe "generated MFA enrollment" do
  before do
      directory = @directory = Dir.mktmpdir("vouch-enrollment")
      FileUtils.mkdir_p("#{directory}/app/models")
      File.write("#{directory}/app/models/two_factor_credential.rb", <<~RUBY)
        class TwoFactorCredential < ApplicationRecord
          belongs_to :account
        end
      RUBY
      generator = Vouch::Generators::TwoFactorableGenerator.new(["TwoFactorCredential"],
        subject: ["otp_secret"], auth_scope: "user", controller_path: "generated_enrollments")
      generator.destination_root = directory
      generator.invoke_all
      stub_const("GeneratedEnrollments", Module.new)
      load "#{directory}/app/controllers/generated_enrollments/two_factor_credentials_controller.rb"
  end

  after { FileUtils.rm_rf(@directory) if @directory }

  it "enrolls through persisted verification, allows retry, and scopes lookup to the owner" do
    account = create(:account)
    controller = GeneratedEnrollments::TwoFactorCredentialsController.new
    session = {}
    delivered = nil
    allow_any_instance_of(TwoFactorCredential).to receive(:deliver_verification_code) { |_record, code| delivered = code }
    allow(controller).to receive(:current_account).and_return(account)
    allow(controller).to receive(:session).and_return(session)
    allow(controller).to receive(:render)
    allow(controller).to receive(:redirect_to)
    allow(controller).to receive(:user_two_factor_credentials_path).and_return("/users/two_factor_credentials")

    controller.new
    expect(controller.instance_variable_get(:@credential).account).to eq(account)
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
      two_factor_credential: {otp_secret: "enrolled-secret"}))
    controller.create
    credential = controller.instance_variable_get(:@credential)
    expect(credential).to be_persisted
    expect(delivered).to be_present
    expect(session.values).to all(be_a(String))
    expect(controller).to have_received(:render).with(:new, status: :accepted)

    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: credential.id, code: "incorrect"))
    controller.update
    expect(session).not_to be_empty
    expect(credential.reload).not_to be_verified

    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: credential.id, code: delivered))
    controller.update
    expect(credential.reload).to be_verified
    expect(credential).to be_two_factor_enabled
    expect(account.reload).to be_two_factor_enabled
    expect(session).to be_empty

    foreign = create(:account).two_factor_credentials.create!
    allow(controller).to receive(:params).and_return(ActionController::Parameters.new(id: foreign.id, code: delivered))
    expect { controller.update }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
