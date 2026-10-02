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

    # Sets `build_times` in `receipt` from `build`, a build-log entry, or to
    # `build` as it is if `exact` (build times read from a receipt). The rest
    # of the file is kept as is, written as `Tab#write` writes it.
    sig { params(receipt: Pathname, build: BuildLog::Build, exact: T::Boolean).void }
    def self.stamp(receipt, build, exact: false)
      data = JSON.parse(receipt.read)
      data[KEY] = exact ? build : build.slice(*FIELDS).compact
      receipt.atomic_write(JSON.pretty_generate(data))
    end

    # The build times in `formula`'s receipt, nil without them.
    sig { params(formula: Formula).returns(T.nilable(BuildLog::Build)) }
    def self.build_times(formula)
      path = receipt(formula)
      return unless path.file?

      data = JSON.parse(path.read)
      data[KEY] if data.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    # The receipt of `formula`'s keg in `opt`. That is the keg `brew
    # reinstall` reinstalls (it takes the linked keg, else the one in `opt`)
    # and the one it puts in `opt`, even with a newer HEAD keg installed.
    sig { params(formula: Formula).returns(Pathname) }
    def self.receipt(formula) = formula.opt_prefix/AbstractTab::FILENAME

    # The file status of `formula`'s receipt, nil without one.
    sig { params(formula: Formula).returns(T.nilable(File::Stat)) }
    def self.receipt_stat(formula)
      path = receipt(formula)
      path.stat if path.file?
    end

    # Whether brew installed `formula` at `since` or later: its receipt isn't
    # the file it was (`before`, from `receipt_stat`), as brew writes a new
    # one for every keg it installs, poured or built, and a failed reinstall
    # renames the old keg back, receipt and all; and the install time brew
    # wrote into it is no earlier than `since`, which a receipt brew only
    # rewrote (e.g. moving a keg to a new name) keeps.
    sig { params(formula: Formula, since: Time, before: T.nilable(File::Stat)).returns(T::Boolean) }
    def self.installed_since?(formula, since, before:)
      stat = receipt_stat(formula)
      return false if stat.nil?
      return false if before && [stat.dev, stat.ino, stat.mtime] == [before.dev, before.ino, before.mtime]

      JSON.parse(receipt(formula).read)["time"].to_i >= since.to_i
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
