# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Timed
  # Orders formulae and splits them into batches, one `brew` call each. Pure
  # Ruby: names, dependency edges, keg-only flags and estimates go in, batches
  # come out; no brew calls.
  module Planner
    # Seconds. A keg-only formula estimated above this is slow enough for a
    # reordered build to hurt, so it can force a batch boundary.
    SLOW_SPLIT = 75

    VERBS = [:upgrade, :install, :reinstall].freeze
    # A dependency's own verb (see `plan`).
    DEPENDENCY_VERBS = [:upgrade, :dependency].freeze

    # One `brew <verb>` call. `label` is `"main"` or `"last"`; `reason` says
    # why the batch starts where it does (`nil` for the first main batch, or
    # where only `verb` changes); `verb`, its formulae's own verb from
    # `plan`'s `verbs`, or `nil` for the plan's.
    class Batch < T::Struct
      const :label, String
      const :reason, T.nilable(String)
      const :names, T::Array[String]
      const :verb, T.nilable(Symbol), default: nil
    end

    # The batches to run, and warnings for the caller to show (`opoo`).
    class Result < T::Struct
      const :batches, T::Array[Batch]
      const :warnings, T::Array[String]
    end

    # Batches for `names`, and warnings. `deps` maps a formula to formulae it
    # needs, directly or not; those outside `names` count too, as chains
    # through them are followed; `estimates` maps to seconds. Every name
    # input (`names`, `deps`, `estimates`, `keg_only`, `last`, `exclude`) must
    # use the caller's resolved form, as edges and flags are matched exactly.
    # `verbs` gives a formula of an `install` plan a verb of its own: `:upgrade`
    # for an outdated dependency (`brew upgrade`), `:dependency` for a missing
    # one (`brew install --as-dependency`); the others take `verb`. `pours`
    # are the formulae that will pour a bottle.
    #
    # Order: dependencies first; among formulae whose dependencies are done,
    # pours before source builds; pours of the last one's verb (see `verbs`)
    # first, so verbs change, and so batches split, only where dependencies
    # make them, then quickest first; builds quickest first, whatever the
    # verb, then a formula without a verb of its own, then those of the last
    # one's verb; then by name. Formulae in a dependency cycle, and those
    # that depend on one, come after the rest, with a warning for the caller
    # to show: each cycle is treated as one unit (members quickest first),
    # and units follow the same dependencies-first, quickest-first rule.
    #
    # Batch boundaries:
    # - `upgrade` only, an outdated dependency's included: before a keg-only
    #   formula over `SLOW_SPLIT` that follows a non-keg-only one in the batch
    #   (`brew upgrade` moves keg-only formulae to the front of a call);
    # - all verbs: `last` formulae, their dependents and, of the formulae
    #   with a verb of their own, those that only these need, go in a final
    #   batch;
    # - `install` only: wherever the verb (see `verbs`) changes, as each call
    #   takes one, whether an outdated dependency needs a missing one or the
    #   reverse.
    # A formula that needs another of its batch gets a later call from the
    # runner (`Runner.run`'s `apart`), not a batch of its own.
    sig {
      params(
        verb:      Symbol,
        names:     T::Array[String],
        deps:      T::Hash[String, T::Array[String]],
        estimates: T::Hash[String, Numeric],
        keg_only:  T::Array[String],
        last:      T::Array[String],
        exclude:   T::Array[String],
        verbs:     T::Hash[String, Symbol],
        pours:     T::Array[String],
      ).returns(Result)
    }
    def self.plan(verb:, names:, deps:, estimates:, keg_only: [], last: [], exclude: [], verbs: {}, pours: [])
      raise ArgumentError, "unknown verb #{verb.inspect}" unless VERBS.include?(verb)

      unknown = verbs.reject { |_, own| DEPENDENCY_VERBS.include?(own) }.map { |name, own| "#{own} for #{name}" }
      raise ArgumentError, "unknown verb #{unknown.join(", ")}" if unknown.any?

      set = names.uniq - exclude
      missing = set.reject { |name| estimates.key?(name) }
      raise ArgumentError, "no estimate for #{missing.join(", ")}" if missing.any?

      infinite = set.reject { |name| estimates.fetch(name).finite? }
      raise ArgumentError, "non-finite estimate for #{infinite.join(", ")}" if infinite.any?

      members = Set.new(set)
      needs = set.to_h { |name| [name, needed(name, deps).select { |dep| members.include?(dep) }.to_set] }
      order, warnings = order(needs, estimates, verbs, pours)
      trailing = order.select { |name| last.include?(name) || needs.fetch(name).any? { |dep| last.include?(dep) } }
      loop do
        only_trailing = (order - trailing).select do |name|
          needers = order.select { |other| needs.fetch(other).include?(name) }
          verbs.key?(name) && needers.any? && needers.all? { |other| trailing.include?(other) }
        end
        break if only_trailing.empty?

        trailing.concat(only_trailing)
      end
      trailing, leading = order.partition { |name| trailing.include?(name) }

      batches = [["main", leading], ["last", trailing]].flat_map do |label, group|
        split(verb, label, group, estimates, keg_only, verbs)
      end
      Result.new(batches:, warnings:)
    end

    # Everything `name` needs, directly or not, over the whole graph; includes
    # `name` itself only when it is on a cycle.
    sig { params(name: String, deps: T::Hash[String, T::Array[String]]).returns(T::Set[String]) }
    def self.needed(name, deps)
      seen = Set.new
      stack = deps.fetch(name, []).dup
      while (dep = stack.pop)
        stack.concat(deps.fetch(dep, [])) if seen.add?(dep)
      end
      seen
    end
    private_class_method :needed

    sig {
      params(
        needs:     T::Hash[String, T::Set[String]],
        estimates: T::Hash[String, Numeric],
        verbs:     T::Hash[String, Symbol],
        pours:     T::Array[String],
      ).returns([T::Array[String], T::Array[String]])
    }
    def self.order(needs, estimates, verbs, pours)
      remaining = needs.transform_values(&:dup)
      order = T.let([], T::Array[String])
      warnings = T.let([], T::Array[String])
      until remaining.empty?
        # Pours first, those of the last one's verb, then quickest; then
        # builds, quickest, then named, then of the last one's verb.
        # Finishing one may ready others that are quicker still, so pick one
        # at a time.
        ready = remaining.select { |_, waiting| waiting.empty? }.keys
        last_name = order.last
        same_verb = ->(ready_name) { (last_name && verbs[ready_name] == verbs[last_name]) ? 0 : 1 }
        name = ready.min_by do |ready_name|
          estimate = estimates.fetch(ready_name)
          if pours.include?(ready_name)
            [0, same_verb.call(ready_name), estimate, 0, ready_name]
          else
            [1, estimate, verbs.key?(ready_name) ? 1 : 0, same_verb.call(ready_name), ready_name]
          end
        end
        if name.nil?
          stuck_order, warning = order_stuck(remaining, needs, estimates)
          order.concat(stuck_order)
          warnings << warning
          break
        end

        order << name
        remaining.delete(name)
        remaining.each_value { |waiting| waiting.delete(name) }
      end
      [order, warnings]
    end
    private_class_method :order

    # Orders what `order` could not: each cycle collapsed to one unit (members
    # by `[estimate, name]`), units dependencies first, then by the same key.
    # `remaining` maps each formula to the formulae it still waits for.
    # Returns the order and a warning naming each cycle and what waits on them.
    sig {
      params(
        remaining: T::Hash[String, T::Set[String]],
        needs:     T::Hash[String, T::Set[String]],
        estimates: T::Hash[String, Numeric],
      ).returns([T::Array[String], String])
    }
    def self.order_stuck(remaining, needs, estimates)
      units = remaining.keys.map do |name|
        cycle = remaining.keys.select do |other|
          other == name || (needs.fetch(name).include?(other) && needs.fetch(other).include?(name))
        end
        cycle.sort_by { |member| [estimates.fetch(member), member] }
      end.uniq
      cycles = units.select { |unit| unit.size > 1 || needs.fetch(unit.fetch(0)).include?(unit.fetch(0)) }
      waiting = units.to_h do |unit|
        [unit, Set.new(unit.flat_map { |member| remaining.fetch(member).to_a }) - unit]
      end

      order = T.let([], T::Array[String])
      until units.empty?
        ready = units.select { |unit| waiting.fetch(unit).empty? }
        unit = ready.min_by { |ready_unit| [estimates.fetch(ready_unit.fetch(0)), ready_unit.fetch(0)] }
        raise "cannot order #{units.flatten.join(", ")}" if unit.nil?

        order.concat(unit)
        units.delete(unit)
        waiting.each_value { |others| others.subtract(unit) }
      end

      cycles = cycles.map(&:sort).sort
      behind = order - cycles.flatten
      warning = cycles.map { |cycle| "dependency cycle among #{cycle.join(", ")}" }.join("; ")
      warning += "; also held back: #{behind.join(", ")}" if behind.any?
      [order, "#{warning}; planned last, quickest first"]
    end
    private_class_method :order_stuck

    sig {
      params(
        verb:      Symbol,
        label:     String,
        group:     T::Array[String],
        estimates: T::Hash[String, Numeric],
        keg_only:  T::Array[String],
        verbs:     T::Hash[String, Symbol],
      ).returns(T::Array[Batch])
    }
    def self.split(verb, label, group, estimates, keg_only, verbs)
      batches = T.let([], T::Array[Batch])
      current = T.let([], T::Array[String])
      reason = T.let((label == "last") ? "--last" : nil, T.nilable(String))

      group.each do |name|
        # The verb shows where only it changes.
        new_verb = current.any? && verbs[name] != verbs[current.fetch(0)]
        why = if !new_verb && verbs.fetch(name, verb) == :upgrade && estimates.fetch(name) > SLOW_SPLIT &&
                 keg_only.include?(name) && current.any? { |other| keg_only.exclude?(other) }
          "keg-only #{name}"
        end

        if new_verb || why
          batches << Batch.new(label:, reason:, names: current, verb: verbs[current.fetch(0)])
          current = []
          reason = why
        end
        current << name
      end
      batches << Batch.new(label:, reason:, names: current, verb: verbs[current.fetch(0)]) unless current.empty?
      batches
    end
    private_class_method :split
  end
end
