require 'rails_helper'
require 'open3'

RSpec.describe 'Rails eager loading' do
  it 'loads the complete host with the gem controllers and credential models' do
    output, status = Open3.capture2e({'RAILS_ENV' => 'test'}, RbConfig.ruby, '-e',
      'require_relative "spec/dummy/config/environment"; Rails.application.eager_load!; puts "eager loading passed"',
      chdir: File.expand_path('../..', __dir__))
    expect(status.success?).to be(true), output
    expect(output).to include('eager loading passed')
  end
end
