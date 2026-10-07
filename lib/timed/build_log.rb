# typed: strict
# frozen_string_literal: true

require "json"

module Timed
  # The build-time database: one JSON file in the user config home, in
  # schema version 1 (`schema_version: 1`, `packages.<name>.builds[]`).
  #
  # Records are plain JSON hashes so fields this code does not know about
  # survive a read-modify-write.
  class BuildLog
    SCHEMA_VERSION = 1

    # Fields kept from a recorded build, plus `verb` (`install`, `upgrade` or
    # `reinstall`).
    ENTRY_KEYS = %w[version started build_seconds install_seconds wall_seconds status batch problems log verb].freeze

    DURATION_KEYS = %w[build_seconds install_seconds wall_seconds].freeze

    # One week: far beyond any build, and small enough that statistics cannot overflow.
    MAX_DURATION_SECONDS = 604_800

    # An LLM's estimate: its answers are clamped to this, so the log keeps
    # nothing else.
    ESTIMATE_SECONDS = T.let(1..(48 * 60 * 60), T::Range[Integer])

    POURED_ESTIMATE = 15.0
    NO_HISTORY_ESTIMATE = 600.0

    # Statistics over a list of durations in seconds.
    class Summary < T::Struct
      const :n, Integer
      const :median, Float
      const :mean, Float
      # Most common whole number of minutes, in seconds.
      const :mode, Integer
      const :stdev, Float
    end

    Database = T.type_alias { T::Hash[String, T.untyped] }
    Build = T.type_alias { T::Hash[String, T.untyped] }

    sig { returns(Pathname) }
    def self.default_path
      Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json"
    end

    sig { params(path: Pathname).returns(BuildLog) }
    def self.load(path)
      return new unless path.exist?

      data = begin
        JSON.parse(path.read)
      rescue JSON::ParserError
        raise "#{path} is not valid JSON."
      end
      validate!(path, data)

      new(data)
    end

    # The checks a database must pass to be read, also run on a changed one
    # before it is written so an invalid change never reaches the file.
    sig { params(path: Pathname, data: T.anything).void }
    def self.validate!(path, data)
      case data
      when Hash then nil
      else raise "#{path} is not a build log: expected a JSON object."
      end

      version = data["schema_version"]
      raise "#{path} has schema version #{version.inspect}; only #{SCHEMA_VERSION} is supported." if version != SCHEMA_VERSION
      raise "#{path} is not a build log: `packages` must be a JSON object." unless data["packages"].is_a?(Hash)

      data["packages"].each do |name, package|
        builds = package.is_a?(Hash) ? package["builds"] : nil
        unless builds.is_a?(Array)
          raise "#{path} is not a build log: package `#{name}` must be a JSON object with a `builds` array."
        end

        builds.each_with_index { |build, index| validate_build!(path, name, build, index) }
      end

      estimates = data.fetch("estimates", {})
      raise "#{path} is not a build log: `estimates` must be a JSON object." unless estimates.is_a?(Hash)

      estimates.each do |name, estimate|
        if estimate.is_a?(Hash) && estimate["version"].is_a?(String) &&
           duration?(estimate["seconds"], ESTIMATE_SECONDS)
          next
        end

        raise "#{path} is not a build log: estimate of `#{name}` must be a JSON object with a `version` string " \
              "and `seconds` from #{ESTIMATE_SECONDS.begin} to #{ESTIMATE_SECONDS.end}."
      end

      # Everything read must be writable back, so `update` cannot fail on it.
      JSON.generate(data)
    rescue JSON::JSONError => e
      raise "#{path} is not a build log: #{e.message}"
    end
    private_class_method :validate!

    sig { params(path: Pathname, name: String, build: T.anything, index: Integer).void }
    def self.validate_build!(path, name, build, index)
      prefix = "#{path} is not a build log:"
      case build
      when Hash then nil
      else raise "#{prefix} build #{index} of package `#{name}` must be a JSON object."
      end

      if build.key?("problems") && !build["problems"].is_a?(Array)
        raise "#{prefix} `problems` of build #{index} of package `#{name}` must be an array."
      end

      if build.key?("started") && !build["started"].is_a?(String)
        raise "#{prefix} `started` of build #{index} of package `#{name}` must be a string."
      end

      DURATION_KEYS.each do |key|
        value = build[key]
        next if value.nil? || duration?(value)

        raise "#{prefix} `#{key}` of build #{index} of package `#{name}` must be a number of seconds " \
              "from 0 to #{MAX_DURATION_SECONDS}."
      end
    end
    private_class_method :validate_build!

    sig { params(value: T.anything, range: T::Range[Integer]).returns(T::Boolean) }
    def self.duration?(value, range = 0..MAX_DURATION_SECONDS)
      case value
      # Not `between?`, which raises for NaN.
      when Integer, Float then range.cover?(value)
      else false
      end
    end
    private_class_method :duration?

    # Read-modify-write under an exclusive lock on `<path>.lock`, as Homebrew
    # does for `trust.json`, writing through a symlinked `path` to its target.
    # Nothing is written if the block raises or leaves the data unchanged.
    sig {
      type_parameters(:U)
        .params(path: Pathname, _block: T.proc.params(log: BuildLog).returns(T.type_parameter(:U)))
        .returns(T.type_parameter(:U))
    }
    def self.update(path, &_block)
      existed = path.dirname.exist?
      path.dirname.mkpath
      path.dirname.chmod(0700) unless existed
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0600) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        target = path.realdirpath
        log = load(target)
        before = JSON.generate(log.to_h)
        result = yield log
        validate!(target, log.to_h)
        after = JSON.generate(log.to_h)
        if after != before
          # Validate what will be in the file, not the in-memory values:
          # a `Rational` is a number here but a string in JSON.
          written = JSON.parse(after)
          validate!(target, written)
          target.atomic_write("#{JSON.pretty_generate(sort_keys(written))}\n")
          target.chmod(0600)
        end
        result
      end
    end

    sig { params(value: T.untyped).returns(T.untyped) }
    def self.sort_keys(value)
      case value
      when Hash then value.sort_by { |key, _| key }.to_h { |key, child| [key, sort_keys(child)] }
      when Array then value.map { |child| sort_keys(child) }
      else value
      end
    end
    private_class_method :sort_keys

    sig { params(values: T::Array[Float]).returns(T.nilable(Summary)) }
    def self.summarise(values)
      return if values.empty?

      minutes = values.map { |value| (value / 60).round(half: :even).to_i }
      minutes_by_frequency = minutes.tally.sort_by { |minute, count| [-count, minute] }
      Summary.new(
        n:      values.length,
        median: median(values),
        mean:   mean(values),
        mode:   minutes_by_frequency.fetch(0).first * 60,
        stdev:  stdev(values),
      )
    end

    sig { params(seconds: T.nilable(Float)).returns(String) }
    def self.format_duration(seconds)
      return "?" if seconds.nil?

      hours, remainder = seconds.round(half: :even).to_i.divmod(3600)
      minutes, secs = remainder.divmod(60)
      return format("%<h>dh%<m>02dm", h: hours, m: minutes) if hours.positive?

      format("%<m>dm%<s>02ds", m: minutes, s: secs)
    end

    sig { params(values: T::Array[Float]).returns(Float) }
    def self.mean(values) = values.sum(0.0) / values.length

    sig { params(values: T::Array[Float]).returns(Float) }
    def self.median(values)
      sorted = values.sort
      middle = sorted.length / 2
      sorted.length.odd? ? sorted.fetch(middle) : (sorted.fetch(middle - 1) + sorted.fetch(middle)) / 2
    end

    # Sample standard deviation; zero for a single value.
    sig { params(values: T::Array[Float]).returns(Float) }
    def self.stdev(values)
      return 0.0 if values.length < 2

      average = mean(values)
      Math.sqrt(values.sum { |value| (value - average)**2 } / (values.length - 1))
    end

    sig { params(data: T.nilable(Database)).void }
    def initialize(data = nil)
      @data = T.let(data || { "schema_version" => SCHEMA_VERSION, "packages" => {} }, Database)
    end

    sig { returns(Database) }
    def to_h = @data

    sig { returns(T::Array[String]) }
    def package_names = packages.keys.sort

    sig { params(name: String).returns(T::Array[Build]) }
    def builds(name) = packages.dig(short_name(name), "builds") || []

    # Appends `entry` (keeping only `ENTRY_KEYS`, dropping nil and empty
    # values) to the formula's builds.
    sig { params(name: String, entry: T::Hash[String, T.untyped]).void }
    def record(name, entry)
      package = packages[short_name(name)] ||= { "builds" => [] }
      package.fetch("builds") << entry.slice(*ENTRY_KEYS).reject { |_, value| value.nil? || value == [] }
    end

    # Appends a problem to the formula's latest build and returns that build,
    # or nil when the formula has none.
    sig { params(name: String, text: String).returns(T.nilable(Build)) }
    def add_note(name, text)
      latest = builds(name).last
      return if latest.nil?

      (latest["problems"] ||= []) << text
      latest
    end

    # Keeps an LLM's estimate of the formula's source build of `version`,
    # replacing any earlier one.
    sig { params(name: String, version: String, seconds: Float, model: String, date: String).void }
    def cache_estimate(name, version:, seconds:, model:, date:)
      (@data["estimates"] ||= {})[short_name(name)] = { "version" => version, "seconds" => seconds, "model" => model,
                                                        "date" => date }
    end

    # The LLM's estimate of the formula's source build of `version`, if kept.
    sig { params(name: String, version: String).returns(T.nilable(Float)) }
    def cached_estimate(name, version)
      estimate = estimates[short_name(name)]
      estimate["seconds"].to_f if estimate && estimate["version"] == version
    end

    # The LLM's estimates kept, by formula.
    sig { returns(T::Hash[String, T::Hash[String, T.untyped]]) }
    def estimates = @data.fetch("estimates", {})

    # Durations in seconds of the formula's builds with `status` (`built` or
    # `poured`; both when nil), of `version` only if given. `install_seconds`
    # wins over `build_seconds` unless it is zero.
    sig { params(name: String, status: T.nilable(String), version: T.nilable(String)).returns(T::Array[Float]) }
    def durations(name, status: nil, version: nil)
      builds(name).filter_map do |build|
        next unless (status ? [status] : %w[built poured]).include?(build["status"])
        next if version && build["version"] != version

        self.class.duration(build)
      end
    end

    # Seconds a build took: `install_seconds` unless it is zero or missing,
    # else `build_seconds`; nil if neither is.
    sig { params(build: Build).returns(T.nilable(Float)) }
    def self.duration(build)
      seconds = [build["install_seconds"], build["build_seconds"]].find { |value| value.to_f.nonzero? }
      seconds&.to_f
    end

    # Seconds the formula is expected to take, from history of the same kind
    # only. Pours: own mean, else median of every pour, else 15s. Builds: own
    # `mean + 1.5*stdev` (`:median` for the median; one sample is used as is),
    # else nil for the caller to guess.
    sig { params(name: String, pour: T::Boolean, estimator: Symbol).returns(T.nilable(Float)) }
    def estimate(name, pour:, estimator: :mean)
      if pour
        own = durations(name, status: "poured")
        return self.class.mean(own) unless own.empty?

        all = package_names.flat_map { |package| durations(package, status: "poured") }
        return all.empty? ? POURED_ESTIMATE : self.class.median(all)
      end

      xs = durations(name, status: "built")
      return if xs.empty?
      return self.class.median(xs) if estimator == :median

      self.class.mean(xs) + (1.5 * self.class.stdev(xs))
    end

    # Median of per-formula mean build times, for a build with no history and
    # no guess.
    sig { returns(Float) }
    def fallback_estimate
      means = package_names.filter_map do |package|
        xs = durations(package, status: "built")
        self.class.mean(xs) unless xs.empty?
      end
      means.empty? ? NO_HISTORY_ESTIMATE : self.class.median(means)
    end

    private

    sig { returns(T::Hash[String, T.untyped]) }
    def packages = @data.fetch("packages")

    sig { params(name: String).returns(String) }
    def short_name(name) = Utils.name_from_full_name(name)
  end
end
