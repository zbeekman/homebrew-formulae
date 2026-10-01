# typed: strict
# frozen_string_literal: true

require "formula"
require "json"
require "tab"
require "utils/output"
require_relative "build_log"

module Timed
  # A formula's build times, mirrored from the build log into its keg's
  # install receipt under `build_times`. Brew reads receipts with `Tab`,
  # which ignores keys it doesn't know, and drops them when it rewrites one.
  module Receipts
    extend Utils::Output::Mixin

    KEY = "build_times"

    # The fields of a logged build that go into a receipt.
    FIELDS = %w[verb started install_seconds build_seconds wall_seconds].freeze

    # Sets `build_times` in `receipt` from `build`, a build-log entry. The
    # rest of the file is kept as is, written as `Tab#write` writes it.
    sig { params(receipt: Pathname, build: BuildLog::Build).void }
    def self.stamp(receipt, build)
      data = JSON.parse(receipt.read)
      data[KEY] = build.slice(*FIELDS).compact
      receipt.atomic_write(JSON.pretty_generate(data))
    end

    # The install time brew wrote into the receipt of `formula`'s keg in
    # `opt`, as whole seconds; nil without one. That is the keg `brew
    # reinstall` reinstalls (it takes the linked keg, else the one in `opt`)
    # and the one it puts in `opt`, even with a newer HEAD keg installed.
    sig { params(formula: Formula).returns(T.nilable(Integer)) }
    def self.install_time(formula)
      receipt = formula.opt_prefix/AbstractTab::FILENAME
      JSON.parse(receipt.read)["time"]&.to_i if receipt.file?
    end

    # Whether brew installed `formula` at `since` or later, by the install
    # time it writes into the receipt of every keg it installs, poured or
    # built: a time other than `before`, the one it had then, as a failed
    # reinstall puts the old keg back, with its receipt, which may be from the
    # same second.
    sig { params(formula: Formula, since: Time, before: T.nilable(Integer)).returns(T::Boolean) }
    def self.installed_since?(formula, since, before:)
      time = install_time(formula)
      !time.nil? && time != before && time >= since.to_i
    end

    # Stamps each installed keg of the formulae `names` whose receipt has no
    # `build_times` yet, from the latest build of the keg's version in `log`
    # of the kind the receipt records: `poured` if it was poured from a
    # bottle, `built` otherwise. Returns the receipts stamped.
    sig { params(log: BuildLog, names: T::Array[String], cellar: Pathname).returns(T::Array[Pathname]) }
    def self.restamp(log, names, cellar: HOMEBREW_CELLAR)
      names.map { |name| Utils.name_from_full_name(name) }.uniq.sort.flat_map do |name|
        builds = log.builds(name)
        (cellar/name).glob("*/#{AbstractTab::FILENAME}").sort.select do |receipt|
          version = receipt.dirname.basename.to_s
          next false if builds.none? { |build| build["version"] == version }

          data = begin
            JSON.parse(receipt.read)
          rescue JSON::ParserError
            nil
          end
          unless data.is_a?(Hash)
            opoo "#{receipt} is not an install receipt; not stamping it."
            next false
          end
          next false if data.key?(KEY)

          status = data["poured_from_bottle"] ? "poured" : "built"
          build = builds.rfind { |candidate| candidate["version"] == version && candidate["status"] == status }
          next false if build.nil?

          stamp(receipt, build)
          true
        end
      end
    end
  end
end
