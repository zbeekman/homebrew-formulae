# typed: strict
# frozen_string_literal: true

require "utils"
require_relative "build_log"

module Timed
  # Reads what brew printed while running a batch.
  module Runner
    # A line of a batch's output and when it arrived, in seconds since the
    # batch started on a monotonic clock; nil when unknown, e.g. in a saved log.
    Line = T.type_alias { [String, T.nilable(Float)] }

    # Colours, which brew adds with `HOMEBREW_COLOR` and builds add anyway.
    ANSI = /\e\[[\d;]*[A-Za-z]/

    # Where brew starts on a formula, with any options after the name: each
    # upgrade (`Upgrade.print_upgrade_message`), each reinstall
    # (`Reinstall.reinstall_formula`), and an install once its dependencies
    # are installed (`FormulaInstaller#install`); and where it starts on a
    # dependency (`FormulaInstaller#install_dependency`). A plain install
    # with no dependencies to install has no heading, and a tap formula's
    # (`Formula#print_tap_action`) isn't read.
    HEADING = /\A==> (?:Upgrading|Installing|Reinstalling) (?<name>[^\s:]+)(?: --\S.*| *)\z/
    DEPENDENCY_HEADING = /\A==> (?:Upgrading|Installing) \S+ dependency: (?<name>\S+)\z/

    # A download failed (`DownloadQueue`). A bottle's version is the keg's
    # (`pkg_version`), a source download's has no revision, so it isn't kept.
    FETCH_FAILED = /\A✘ (?<kind>Formula|Bottle) (?<name>\S+) \((?<version>[^)]+)\)\z/

    # `FormulaInstaller#summary`: the install badge, unless turned off, then
    # the keg, its size and, for a source build, `built in <duration>`.
    SUMMARY = %r{
      \A(?:.*\s)?/\S*/(?<name>[^/\s]+)/(?<version>[^/\s:]+):
      \s(?:[\d,]+\sfiles,\s)?[\d.]+[KMGTP]?B(?:,\sbuilt\sin\s(?<built>.+))?\z
    }x

    INSTALL_TIMES = "==> Installation times"

    # `Messages#display_install_times` rows.
    INSTALL_TIME = /\A(?<name>\S+)\s+(?<seconds>\d+\.\d+) s\z/

    # An error, kept with up to `PROBLEM_LINES - 1` lines after it, until a
    # blank line, brew's next status line or the next error. Brew's own
    # errors all start with `Error:`. A failed build prints the end of its
    # log under a line naming the log and how many lines follow (unless
    # verbose); that line is kept with the last `PROBLEM_LINES - 1` of those
    # lines, blank ones and errors included but trailing blank ones dropped,
    # stopping early at brew's next status line.
    PROBLEM = /\A(?:Error:|Last (?<tail>\d+) lines from )/
    STATUS = /\A(?:==>|✔︎|✘|🍺)/
    PROBLEM_LINES = 6

    # A log no longer than the lines brew prints is printed whole, starting
    # with the time it was written (`Formula#system`), and brew's own text
    # may follow within the count (`BuildError#dump`): its first line, or two
    # blank lines in a row, end such a log.
    LOG_START = /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}\z/
    AFTER_LOG = /
      \A(?:#{Regexp.union("READ THIS: ", "If reporting this issue please do so ", "These open issues may also help:")}
      |This\sis\sa\sTier\s\d\sconfiguration:)
    /x

    # Builds by formula name from a batch's output, as the build log records
    # them: every formula brew started on, including those it installed or
    # upgraded alongside the batch. `version` is the keg's, from brew's last
    # summary line for the formula or a failed bottle download; `status` is
    # `built` or `poured` from that summary line, else `failed`;
    # `install_seconds` from the `Installation times` table
    # (`--display-times`); `build_seconds` from that summary's `built in`;
    # `problems` from errors printed while brew was working on the formula,
    # from where it names it to its summary line. `started` is the batch's
    # `started` plus when the formula was first named (the batch's start
    # without a time for that), and `wall_seconds` the time from then to its
    # summary line (nil without both times).
    sig { params(lines: T::Array[Line], started: T.nilable(Time)).returns(T::Hash[String, BuildLog::Build]) }
    def self.parse(lines, started: nil)
      parser = Parser.new
      lines.each { |line, time| parser.feed(line, time) }
      parser.builds(started)
    end

    # The state `parse` needs between lines.
    class Parser
      sig { void }
      def initialize
        @builds = T.let({}, T::Hash[String, BuildLog::Build])
        @first_seen = T.let({}, T::Hash[String, Float])
        @finished = T.let({}, T::Hash[String, Float])
        @current = T.let(nil, T.nilable(String))
        @problem = T.let(nil, T.nilable(T::Array[String]))
        # Lines of a failed build's log still to come, while reading them.
        @tail = T.let(nil, T.nilable(Integer))
        # Whether that log is printed whole, known from its first line.
        @whole_log = T.let(false, T::Boolean)
        @in_times = T.let(false, T::Boolean)
      end

      sig { params(raw: String, time: T.nilable(Float)).void }
      def feed(raw, time)
        line = raw.chomp.gsub(ANSI, "")
        return if (problem = @problem) && took_problem_line?(problem, line)

        if @in_times && (row = INSTALL_TIME.match(line))
          build(row[:name].to_s)["install_seconds"] = row[:seconds].to_f
          return
        end

        @in_times = line == INSTALL_TIMES
        if (match = HEADING.match(line) || DEPENDENCY_HEADING.match(line))
          @current = seen(match[:name].to_s, time)
        elsif (match = FETCH_FAILED.match(line))
          @current = seen(match[:name].to_s, time)
          build(@current)["version"] = match[:version] if match[:kind] == "Bottle"
        elsif (match = SUMMARY.match(line))
          name = seen(match[:name].to_s, time)
          @finished[name] = time if time
          built = match[:built]
          build(name).merge!("version"       => match[:version], "status" => built ? "built" : "poured",
                             "build_seconds" => (duration(built) if built))
          # Brew is done with it: anything printed before it names another
          # formula is about the run.
          @current = nil if @current == name
        elsif @current && (match = PROBLEM.match(line))
          @problem = [line]
          @tail = match[:tail]&.to_i
        end
      end

      sig { params(started: T.nilable(Time)).returns(T::Hash[String, BuildLog::Build]) }
      def builds(started)
        close_problem
        @builds.to_h do |name, build|
          first = @first_seen[name]
          finished = @finished[name]
          timing = {
            "started"      => (started + (first || 0) if started)&.iso8601,
            "wall_seconds" => ((finished - first).round(1) if first && finished),
          }
          result = build.merge(timing).compact
          result["status"] ||= "failed"
          [name, result]
        end
      end

      private

      sig { params(name: String).returns(BuildLog::Build) }
      def build(name) = @builds[name] ||= {}

      # `name` as brew's summary and times name it, noting when it was first
      # named.
      sig { params(name: String, time: T.nilable(Float)).returns(String) }
      def seen(name, time)
        short = Utils.name_from_full_name(name)
        build(short)
        @first_seen[short] ||= time if time
        short
      end

      # Adds `line` to `problem` and returns true, or closes `problem` and
      # returns false if `line` isn't part of it.
      sig { params(problem: T::Array[String], line: String).returns(T::Boolean) }
      def took_problem_line?(problem, line)
        tail = @tail
        if tail
          @whole_log = LOG_START.match?(line) if problem.length == 1
          log_ended = @whole_log &&
                      (AFTER_LOG.match?(line) || (line.blank? && problem.length > 1 && problem.fetch(-1).blank?))
          if tail.positive? && !STATUS.match?(line) && !log_ended
            @tail = tail - 1
            problem << line
            return true
          end
        elsif !STATUS.match?(line) && line.present? && !PROBLEM.match?(line) && problem.length < PROBLEM_LINES
          problem << line
          return true
        end

        close_problem
        false
      end

      sig { void }
      def close_problem
        problem = @problem
        current = @current
        tail = @tail
        @problem = nil
        @tail = nil
        return if problem.nil? || current.nil?

        if tail
          log = problem.drop(1)
          log.pop while (last = log.last) && last.blank?
          problem = [problem.fetch(0), *log.last(PROBLEM_LINES - 1)]
        end
        problems = build(current)["problems"] ||= []
        text = problem.join("\n")
        problems << text unless problems.include?(text)
      end

      # Seconds in a duration as `pretty_duration` prints it, e.g.
      # `1 hour 26 minutes`.
      sig { params(text: String).returns(Float) }
      def duration(text)
        { "hour" => 3600, "minute" => 60, "second" => 1 }.sum do |unit, seconds|
          text[/(\d+) #{unit}/, 1].to_f * seconds
        end
      end
    end
    private_constant :Parser
  end
end
