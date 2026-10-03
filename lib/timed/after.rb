# typed: strict
# frozen_string_literal: true

require "formula"
require "utils"

module Timed
  # Here rather than with the rest of `Runner`, which loads `Command`, so that
  # `Command`, which makes these, needn't load `Runner`.
  module Runner
    # A `brew <verb> --formula --yes --display-times <flags> <formulae>` call
    # after the batches, logged as the `label` batch. It gives brew what
    # `choose` returns once the calls before it are done, from the formulae
    # the run installed (by short name, as logged, with how: `built` or
    # `poured`) and those that failed, were skipped or weren't finished (by
    # full name). If Ctrl-C stops the run before the call, it still works out
    # what it would have given brew, and says so; if Ctrl-C stops that too,
    # it names the `candidates` it may have given brew, known before the
    # batches (nil if none are). `noun` names them in messages, e.g.
    # `outdated dependent`, and `finish` gives the command that finishes
    # what the call left of them; `deps` gives the full names of the
    # formulae each needs, as `run`'s `deps` does, so one that needs a
    # formula that failed or was skipped is skipped, or named apart, with
    # what to run once that formula installs. As `brew reinstall` stops at a
    # failed build, and leaves the old version installed, a reinstall gives
    # brew one formula per call and takes only a new receipt as reinstalled.
    class After < T::Struct
      const :label, String
      const :verb, String
      const :flags, T::Array[String]
      const :noun, String
      const :candidates, T.nilable(T::Array[Formula])
      const :deps, T.proc.params(formula: Formula).returns(T::Array[String])
      const :choose, T.proc.params(installed: T::Hash[String, String], blocked: T::Array[String])
                      .returns(T::Array[Formula])
      const :finish, T.proc.params(left: T::Array[String]).returns(String)

      sig { returns(T::Boolean) }
      def reinstall? = verb == "reinstall"

      # E.g. `Outdated dependents`.
      sig { returns(String) }
      def what = ::Utils.pluralize(noun, 2).capitalize

      # E.g. `upgraded`.
      sig { returns(String) }
      def done = verb.end_with?("e") ? "#{verb}d" : "#{verb}ed"

      # E.g. `Outdated dependents not upgraded: a b; to finish, run:`, then
      # the command.
      sig { params(left: T::Array[String]).returns(String) }
      def left_message(left) = "#{what} not #{done}: #{left.join(" ")}; to finish, run:\n  #{finish.call(left)}"
    end
  end
end
