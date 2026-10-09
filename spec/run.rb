# typed: strict
# frozen_string_literal: true

# Runs this tap's specs under Homebrew's Ruby, as `brew tests` runs brew's:
#
#   brew ruby -- spec/run.rb [<rspec options>] [<spec files>]
#
# Spec paths are relative to the root of the checkout this file is in, so the
# tapped copy and any worktree each run their own specs.

require "tmpdir"

# Like `brew tests`, a dev-cmd, which this runner stands in for. Brew's spec
# helper needs `rubocop` from `style` as well as `tests`.
Utils::GemSetup.install_bundler_gems!(groups: %w[style tests]) # rubocop:disable Homebrew/InstallBundlerGems

# Match `brew tests`' environment: no user configuration, and a throwaway
# `HOME` so brew's spec teardown never touches the real `trust.json`.
Homebrew::EnvConfig::ENVS.each_key do |env|
  ENV.delete(env.to_s) unless [:HOMEBREW_CACHE, :HOMEBREW_LOGS, :HOMEBREW_TEMP].include?(env)
end
# Nor a proxy of the shell, which curl would send even a request to
# `localhost` through, past the network guard. These are the upper-case ones
# `bin/brew` passes on (`HTTPS_PROXY`, `FTP_PROXY`, `ALL_PROXY`); the
# lower-case ones are in `Homebrew::EnvConfig::ENVS`, cleared above. A spec
# that needs one sets it itself.
ENV.keys.grep(/\A(?:http|https|ftp|all)_proxy\z/i).each { |proxy| ENV.delete(proxy) }
ENV["HOMEBREW_TESTS"] = "1"
ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
ENV["HOMEBREW_NO_ANALYTICS_THIS_RUN"] = "1"
ENV["HOMEBREW_SORBET_RUNTIME"] = "1"
ENV["HOMEBREW_SORBET_RECURSIVE"] = "1"

rspec_args = ["--require", "spec_helper"]
rspec_args += ["--format", "progress", "--format", "RSpec::Github::Formatter"] if ENV["GITHUB_ACTIONS"]

success = Dir.mktmpdir("homebrew-tap-specs-", HOMEBREW_TEMP) do |home|
  ENV["HOME"] = home
  ENV["HOMEBREW_USER_CONFIG_HOME"] = "#{home}/.homebrew"
  system("bundle", "exec", "rspec", *rspec_args, *ARGV, chdir: File.expand_path("..", __dir__))
end
exit success ? 0 : 1
