# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Documented registration form" do
  let(:form_class) do
    path = Rails.root.join("..", "..", "docs", "registration.md")
    source = File.read(path).scan(/```ruby\n(.*?)```/m).flatten.find do |block|
      block.include?("# app/forms/signup_form.rb\nclass SignupForm")
    end
    raise "Registration guide is missing its complete SignupForm example" unless source

    eval(source.sub("class SignupForm\n", "Class.new do\n"), TOPLEVEL_BINDING, path.to_s)
  end

  before do
    stub_const("SignupForm", form_class)
    stub_const("Phone", Class.new(TwoFactorCredential))
    stub_const("Email", Class.new(TwoFactorCredential))
    allow_any_instance_of(Phone).to receive(:deliver_verification_code) { |_record, code| @code = code }
  end

  def credentials_record(persisted: false)
    record = persisted ? create(:account) : Account.new(email_address: "chosen@example.test")
    profile = Struct.new(:timezone).new
    record.define_singleton_method(:profile) { profile }
    record
  end

  def verified_phone
    phone = Phone.new(type: "phone", otp_secret: "+61400000000")
    issued = phone.start_verification!
    phone.complete_verification!(@code, token: issued.token)
    phone
  end

  def draft_for(phone)
    {"timezone" => "Australia/Brisbane", "step" => 2,
      "contact_states" => {"phones" => {phone.verification_subject_key => phone.serialize_verification_state}}}
  end

  it "restores first-step fields while omitting passwords from session data" do
    form = SignupForm.new(credentials_record)
    form.assign_attributes(timezone: "Australia/Brisbane", password: "never-serialize-me", step: 2)

    data = form.serialize
    restored = SignupForm.deserialize(data, credentials_record)

    expect(restored.timezone).to eq("Australia/Brisbane")
    expect(restored.step).to eq(2)
    expect(data.to_json).not_to include("password", "never-serialize-me")
  end

  it "keeps an expired proof visible and clears the error after re-verifying that subject" do
    original = verified_phone
    data = draft_for(original)
    subject = original.verification_subject_key

    travel Vouch.configuration.pending_authentication_ttl + 1 do
      form = SignupForm.deserialize(data, credentials_record)
      expect(form).not_to be_valid
      expect(form.unavailable_contacts).to eq([["phones", subject]])
      expect(form.serialize.fetch("contact_states").fetch("phones")).to eq(data.fetch("contact_states").fetch("phones"))

      replacement = verified_phone
      data["contact_states"]["phones"][subject] = replacement.serialize_verification_state
      restored = SignupForm.deserialize(data, credentials_record)

      expect(restored).to be_valid
      expect(restored.unavailable_contacts).to be_empty
      expect(restored.phones.sole).to be_verified
    end
  end

  it "removes an expired contact without losing other draft fields" do
    original = verified_phone
    data = draft_for(original)

    travel Vouch.configuration.pending_authentication_ttl + 1 do
      form = SignupForm.deserialize(data, credentials_record)
      form.remove_contact("phones", original.verification_subject_key)

      expect(form).to be_valid
      expect(form.serialize.fetch("contact_states").fetch("phones")).to be_empty
      expect(form.timezone).to eq("Australia/Brisbane")
    end
  end

  it "checks that the retained subject matches the verified encrypted record" do
    phone = verified_phone
    data = draft_for(phone)
    data["contact_states"]["phones"] = {'["another phone"]' => phone.serialize_verification_state}

    form = SignupForm.deserialize(data, credentials_record)

    expect(form).not_to be_valid
    expect(form.phones).to be_empty
  end

  it "does not replace an invited account email with a saved draft value" do
    record = credentials_record(persisted: true)
    expected = record.email_address

    form = SignupForm.deserialize({"email_address" => "old-draft@example.test"}, record)

    expect(form.email_address).to eq(expected)
  end

  it "requires a verified factor before enabling MFA" do
    form = SignupForm.deserialize({"timezone" => "UTC", "enable_mfa" => true}, credentials_record)

    expect(form).not_to be_valid
    expect(form.errors[:enable_mfa]).to include("requires a verified contact")
    expect { form.save! }.to raise_error(ActiveModel::ValidationError)
  end
end
