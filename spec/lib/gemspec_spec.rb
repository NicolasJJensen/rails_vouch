# frozen_string_literal: true

require "spec_helper"

RSpec.describe "rails_vouch gem package" do
  let(:specification) do
    Gem::Specification.load(File.expand_path("../../rails_vouch.gemspec", __dir__))
  end

  it "packages the README and the user documentation it references" do
    files = specification.files

    expect(files).to include("README.md")
    expect(files).to include("CHANGELOG.md")
    expect(files).to include("docs/credential-adapter-contract.md")

    readme = File.read(File.expand_path("../../README.md", __dir__))
    guides = readme.scan(/\]\((docs\/[^)#]+\.md)(?:#[^)]*)?\)/).flatten.uniq
    expect(guides).not_to be_empty
    expect(files).to include(*guides)
  end

  it "excludes the internal review notes" do
    files = specification.files

    expect(files).not_to include("docs/agreed-fixes.md")
    expect(files).not_to include("docs/integration-fixes.md")
    expect(files).not_to include("docs/review-fixes.md")
  end
end
