source "https://rubygems.org"

gemspec

gem "rails", ENV.fetch("VOUCH_RAILS", "~> 8.0")

# activesupport 8.1.3 still calls JSON.parse with a second positional argument,
# which json 3.0 removed. Pin json until Rails ships the fix.
gem "json", "< 3"

if ENV["VOUCH_RELEASE_DEPS"] == "1"
  gem "active_hooks"
  gem "otp_courier", "~> 0.2"
else
  gem "active_hooks", path: "../active_hooks"
  gem "otp_courier", path: "../otp_courier"
end

# Feature adapters used by the test suite. They remain optional runtime
# dependencies of the released gem.
group :test do
  gem "omniauth", "~> 2.0"
  gem "rotp", "~> 6.0"
  gem "rqrcode", "~> 3.0"
end
