# typed: strict
# frozen_string_literal: true

# Brew's spec teardown deletes `trust.json` from the user config home, so only
# run inside `spec/run.rb`'s sandboxed environment.
raise "Run the specs with `brew ruby -- spec/run.rb`." unless ENV["HOMEBREW_TESTS"]

require "simplecov"
SimpleCov.start do
  root File.expand_path("..", __dir__)
  enable_coverage :branch
  primary_coverage :line
  cover "{cmd,lib}/**/*.rb"
end

# Brew's own harness: prefix, cache and logs in a temporary directory, `ENV`
# restored and output silenced around each example, `rspec-sorbet` doubles.
require File.join(ENV.fetch("HOMEBREW_LIBRARY"), "Homebrew/test/spec_helper")

RSpec.configure do |config|
  # Brew retries for its network specs; ours are offline, so a retry would
  # only hide a flaky spec.
  config.default_retry_count = 0
end
