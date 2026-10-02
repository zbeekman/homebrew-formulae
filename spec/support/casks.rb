# typed: true
# frozen_string_literal: true

require "cask/cask_loader"

# Casks on disk, as brew loads them, for specs that `include` this.
module TimedCaskHelper
  extend T::Helpers

  requires_ancestor { Test::Helper::Cask }
  requires_ancestor { Test::Helper::MkTmpDir }

  # Cask DSL source for the cask `token` at `version`, with `stanzas`.
  sig { params(token: String, version: String, stanzas: String).returns(String) }
  def cask_source(token, version, stanzas = "")
    <<~RUBY
      cask "#{token}" do
        version "#{version}"
        sha256 :no_check
        url "file:///dev/null"
        #{stanzas}
      end
    RUBY
  end

  # The cask `token` at `latest` with `stanzas`, loaded from a file and then
  # loadable by its token (so `Cask::CaskLoader.for` must call the original
  # for anything else), and installed at `installed_version` (not when nil)
  # with `installed_stanzas`.
  sig {
    params(token: String, installed_version: T.nilable(String), latest: String, stanzas: String,
           installed_stanzas: String).returns(Cask::Cask)
  }
  def stub_cask(token, installed_version = "1.0", latest: "2.0", stanzas: "", installed_stanzas: stanzas)
    if installed_version
      metadata = HOMEBREW_PREFIX/"Caskroom/#{token}/.metadata/#{installed_version}/20260101000000.000"
      (metadata/"Casks").mkpath
      (metadata/"Casks/#{token}.rb").write(cask_source(token, installed_version, installed_stanzas))
    end
    path = mktmpdir/"#{token}.rb"
    path.write(cask_source(token, latest, stanzas))
    cask = Cask::CaskLoader.load(path)
    stub_cask_loader(cask)
    cask
  end
end
