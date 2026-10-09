# typed: strict
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/planner"

RSpec.describe Timed::Planner do
  sig {
    params(
      names:     T::Array[String],
      estimates: T::Hash[String, Numeric],
      deps:      T::Hash[String, T::Array[String]],
      keg_only:  T::Array[String],
      verb:      Symbol,
      last:      T::Array[String],
      exclude:   T::Array[String],
      verbs:     T::Hash[String, Symbol],
      pours:     T::Array[String],
    ).returns(Timed::Planner::Result)
  }
  def result(names, estimates, deps: {}, keg_only: [], verb: :upgrade, last: [], exclude: [], verbs: {}, pours: [])
    described_class.plan(
      verb:, names:, deps:, estimates:, keg_only:, last:, exclude:, verbs:, pours:,
    )
  end

  sig {
    params(
      names:     T::Array[String],
      estimates: T::Hash[String, Numeric],
      deps:      T::Hash[String, T::Array[String]],
      keg_only:  T::Array[String],
      verb:      Symbol,
      last:      T::Array[String],
      exclude:   T::Array[String],
      verbs:     T::Hash[String, Symbol],
      pours:     T::Array[String],
    ).returns(T::Array[T::Array[String]])
  }
  def batches(names, estimates, deps: {}, keg_only: [], verb: :upgrade, last: [], exclude: [], verbs: {},
              pours: [])
    result(names, estimates, deps:, keg_only:, verb:, last:, exclude:, verbs:, pours:).batches.map(&:names)
  end

  describe ".plan order" do
    it "returns no batches for no names" do
      expect(batches([], {})).to eq([])
    end

    it "puts the quickest formula first" do
      expect(batches(%w[b a c], { "a" => 30, "b" => 10, "c" => 20 })).to eq([%w[b c a]])
    end

    it "breaks ties by name" do
      expect(batches(%w[c b a], { "a" => 5, "b" => 5, "c" => 5 })).to eq([%w[a b c]])
    end

    it "puts dependencies before dependents even when the dependent is quicker" do
      expect(batches(%w[app lib], { "app" => 1, "lib" => 50 }, deps: { "app" => %w[lib] }))
        .to eq([%w[lib app]])
    end

    it "runs a quick independent formula before a slow dependency chain" do
      estimates = { "slow" => 50, "app" => 1, "quick" => 10 }
      expect(batches(%w[slow app quick], estimates, deps: { "app" => %w[slow] }))
        .to eq([%w[quick slow app]])
    end

    it "orders each dependent after all of its dependencies" do
      deps = { "d" => %w[b c], "b" => %w[a], "c" => %w[a] }
      estimates = { "a" => 9, "b" => 8, "c" => 7, "d" => 1 }
      expect(batches(%w[d c b a], estimates, deps:)).to eq([%w[a c b d]])
    end

    it "ignores dependencies outside the set" do
      expect(batches(%w[a], { "a" => 1 }, deps: { "a" => %w[elsewhere] })).to eq([%w[a]])
    end

    it "follows chains through formulae outside the set" do
      expect(batches(%w[a b], { "a" => 1, "b" => 50 }, deps: { "a" => %w[x], "x" => %w[b] }))
        .to eq([%w[b a]])
    end

    it "has no warnings without a cycle" do
      warnings = result(%w[a b], { "a" => 1, "b" => 2 }, deps: { "a" => %w[b] }).warnings
      expect(warnings).to eq([])
    end

    it "plans a lone cycle by estimate instead of raising" do
      deps = { "a" => %w[b], "b" => %w[a] }
      expect(batches(%w[a b], { "a" => 5, "b" => 1 }, deps:)).to eq([%w[b a]])
    end

    it "names the cycle members in a warning" do
      deps = { "a" => %w[b], "b" => %w[a] }
      expect(result(%w[a b c], { "a" => 5, "b" => 1, "c" => 1 }, deps:).warnings)
        .to eq(["dependency cycle among a, b; planned last, quickest first"])
    end

    it "plans independent formulae before a cycle, quickest first" do
      deps = { "a" => %w[b], "b" => %w[a] }
      estimates = { "a" => 5, "b" => 6, "c" => 3, "d" => 1 }
      expect(batches(%w[a b c d], estimates, deps:)).to eq([%w[d c a b]])
    end

    it "plans a dependent of a cycle after the cycle, even when it is quicker" do
      deps = { "a" => %w[b], "b" => %w[a], "c" => %w[a] }
      estimates = { "a" => 5, "b" => 6, "c" => 1, "d" => 2 }
      expect(batches(%w[a b c d], estimates, deps:)).to eq([%w[d a b c]])
    end

    it "names the dependents held back by a cycle in the warning" do
      deps = { "a" => %w[b], "b" => %w[a], "c" => %w[a] }
      estimates = { "a" => 5, "b" => 6, "c" => 1, "d" => 2 }
      expect(result(%w[a b c d], estimates, deps:).warnings)
        .to eq(["dependency cycle among a, b; also held back: c; planned last, quickest first"])
    end

    it "orders held-back formulae by their own dependencies, then estimate" do
      deps = { "a" => %w[b], "b" => %w[a], "c" => %w[a], "d" => %w[c] }
      estimates = { "a" => 5, "b" => 6, "c" => 9, "d" => 1, "e" => 3 }
      expect(batches(%w[a b c d e], estimates, deps:)).to eq([%w[e a b c d]])
    end

    it "orders cycles that are ready together by their quickest member" do
      deps = { "a" => %w[b], "b" => %w[a], "c" => %w[d], "d" => %w[c], "e" => %w[a c] }
      estimates = { "a" => 5, "b" => 6, "c" => 1, "d" => 9, "e" => 2 }
      expect(batches(%w[a b c d e], estimates, deps:)).to eq([%w[c d a b e]])
    end

    it "names each cycle separately in the warning" do
      deps = { "a" => %w[b], "b" => %w[a], "c" => %w[d], "d" => %w[c], "e" => %w[a c] }
      estimates = { "a" => 5, "b" => 6, "c" => 1, "d" => 9, "e" => 2 }
      expect(result(%w[a b c d e], estimates, deps:).warnings).to eq(
        ["dependency cycle among a, b; dependency cycle among c, d; also held back: e; " \
         "planned last, quickest first"],
      )
    end

    it "treats a self-edge as a cycle" do
      expect(batches(%w[a b], { "a" => 1, "b" => 9 }, deps: { "a" => %w[a] })).to eq([%w[b a]])
    end

    it "names a self-edge in the warning" do
      warnings = result(%w[a b], { "a" => 1, "b" => 9 }, deps: { "a" => %w[a] }).warnings
      expect(warnings).to eq(["dependency cycle among a; planned last, quickest first"])
    end

    it "moves a whole cycle to the last batch when one member is --last" do
      deps = { "a" => %w[b], "b" => %w[a] }
      expect(batches(%w[a b c], { "a" => 5, "b" => 6, "c" => 1 }, deps:, last: %w[a])).to eq([%w[c], %w[a b]])
    end

    it "rejects a non-finite estimate" do
      expect { result(%w[a], { "a" => Float::NAN }) }.to raise_error(ArgumentError, /non-finite.*a/)
    end

    it "drops excluded formulae" do
      expect(batches(%w[a b c], { "a" => 1, "b" => 2, "c" => 3 }, exclude: %w[b])).to eq([%w[a c]])
    end

    it "does not wait for an excluded dependency" do
      expect(batches(%w[a b], { "a" => 9, "b" => 1 }, deps: { "b" => %w[a] }, exclude: %w[a]))
        .to eq([%w[b]])
    end

    it "requires an estimate for every formula" do
      expect { result(%w[a], {}) }.to raise_error(ArgumentError, /a/)
    end

    it "rejects an unknown verb" do
      expect { result(%w[a], { "a" => 1 }, verb: :remove) }.to raise_error(ArgumentError, /remove/)
    end
  end

  describe ".plan splits: keg-only" do
    sig { returns(T::Hash[String, Numeric]) }
    def estimates
      { "quick" => 10, "jupyterlab" => 200, "llvm" => 3000, "lld" => 400, "flang" => 900 }
    end

    it "keeps one batch when nothing is keg-only" do
      expect(batches(estimates.keys, estimates)).to eq([%w[quick jupyterlab lld flang llvm]])
    end

    it "starts a batch at a slow keg-only formula after a non-keg-only one" do
      result = batches(%w[quick jupyterlab llvm], estimates, keg_only: %w[llvm])
      expect(result).to eq([%w[quick jupyterlab], %w[llvm]])
    end

    it "labels the split with its reason" do
      planned = result(%w[quick llvm], estimates, keg_only: %w[llvm]).batches
      expect(planned.map(&:reason)).to eq([nil, "keg-only llvm"])
    end

    it "does not split for a keg-only formula at the front" do
      expect(batches(%w[llvm], estimates, keg_only: %w[llvm])).to eq([%w[llvm]])
    end

    it "does not split for a keg-only formula quicker than 75s" do
      result = batches(%w[quick jupyterlab kegonly], estimates.merge("kegonly" => 60), keg_only: %w[kegonly])
      expect(result).to eq([%w[quick kegonly jupyterlab]])
    end

    it "does not split at exactly 75s" do
      expect(batches(%w[a k], { "a" => 1, "k" => 75 }, keg_only: %w[k])).to eq([%w[a k]])
    end

    it "splits at 76s" do
      expect(batches(%w[a k], { "a" => 1, "k" => 76 }, keg_only: %w[k])).to eq([%w[a], %w[k]])
    end

    it "does not split when the batch so far is all keg-only" do
      estimates = { "k1" => 100, "k2" => 200 }
      expect(batches(%w[k1 k2], estimates, keg_only: %w[k1 k2])).to eq([%w[k1 k2]])
    end

    it "splits before each slow keg-only formula that follows a non-keg-only one" do
      estimates = { "a" => 100, "k1" => 200, "b" => 300, "k2" => 400 }
      result = batches(estimates.keys, estimates, keg_only: %w[k1 k2])
      expect(result).to eq([%w[a], %w[k1 b], %w[k2]])
    end

    it "does not apply to install" do
      result = batches(%w[quick llvm], estimates, keg_only: %w[llvm], verb: :install)
      expect(result).to eq([%w[quick llvm]])
    end

    it "does not apply to reinstall" do
      result = batches(%w[quick llvm], estimates, keg_only: %w[llvm], verb: :reinstall)
      expect(result).to eq([%w[quick llvm]])
    end

    it "splits the llvm upgrade only before keg-only llvm" do
      deps = { "lld" => %w[llvm], "flang" => %w[llvm] }
      result = batches(estimates.keys, estimates, deps:, keg_only: %w[llvm])
      expect(result).to eq([%w[quick jupyterlab], %w[llvm lld flang]])
    end
  end

  describe ".plan slow dependents" do
    it "keeps a slow formula in the batch of a slow one it needs, whatever the verb, as the runner gives it a " \
       "later call" do
      estimates = { "quick" => 10, "llvm" => 3000, "flang" => 900 }
      deps = { "flang" => %w[llvm] }
      planned = [:upgrade, :install, :reinstall].to_h do |verb|
        [verb, batches(estimates.keys, estimates, deps:, verb:)]
      end
      expect(planned).to eq([:upgrade, :install, :reinstall].to_h { |verb| [verb, [%w[quick llvm flang]]] })
    end
  end

  describe ".plan for reinstall" do
    it "makes one batch whatever the slow and keg-only formulae, as only `--last` splits it" do
      estimates = { "quick" => 10, "llvm" => 3000, "flang" => 900, "lld" => 400, "gcc" => 2000 }
      deps = { "flang" => %w[llvm], "lld" => %w[llvm] }
      planned = batches(estimates.keys, estimates, deps:, keg_only: %w[llvm gcc], verb: :reinstall)
      expect(planned).to eq([%w[quick gcc llvm lld flang]])
    end
  end

  describe ".plan for install, with dependencies of their own verbs" do
    it "puts the pours before the source builds, keeping pours of the last one's verb together, then quickest " \
       "first, whatever their verbs, and gives each batch its names' verb" do
      estimates = { "named_pour" => 1, "missing_pour" => 2, "outdated_pour" => 3, "other_pour" => 4, "build" => 5 }
      verbs = { "missing_pour" => :dependency, "outdated_pour" => :upgrade, "other_pour" => :dependency }
      planned = result(estimates.keys, estimates, verbs:, verb: :install, pours: estimates.keys - %w[build]).batches
      expect(planned.map { |b| [b.verb, b.reason, b.names] }).to eq(
        [[nil, nil, %w[named_pour]], [:dependency, nil, %w[missing_pour other_pour]],
         [:upgrade, nil, %w[outdated_pour]], [nil, nil, %w[build]]],
      )
    end

    it "builds the quickest first, whatever the verb, and, among builds estimated alike, a named formula first, " \
       "then those of the last one's verb, so a named formula never waits behind dependencies of another that " \
       "are no quicker" do
      deps = { "librttopo" => %w[geos], "gdal" => %w[ant zlib geos librttopo llvm proj grpc] }
      verbs = { "ant" => :dependency, "zlib" => :dependency, "geos" => :dependency, "librttopo" => :dependency,
                "llvm" => :dependency, "proj" => :dependency, "grpc" => :upgrade }
      estimates = { "ant" => 1, "librttopo" => 1, "zlib" => 30 }
      estimates = %w[gdal aria2 grpc proj llvm geos].to_h { |name| [name, 97] }.merge(estimates)
      planned = result(estimates.keys, estimates, deps:, verbs:, verb: :install, pours: %w[ant librttopo]).batches
      expect(planned.map { |b| [b.verb, b.names] }).to eq(
        [[:dependency, %w[ant zlib]], [nil, %w[aria2]], [:dependency, %w[geos librttopo llvm proj]],
         [:upgrade, %w[grpc]], [nil, %w[gdal]]],
      )
    end

    it "starts a batch wherever the verb changes along the order, as brew takes one verb per call, even where " \
       "that splits a verb, as an outdated dependency needs a missing one or the reverse" do
      estimates = { "missing" => 10, "outdated" => 20, "other" => 5 }
      deps = { "outdated" => %w[missing], "other" => %w[outdated] }
      verbs = { "missing" => :dependency, "outdated" => :upgrade, "other" => :dependency }
      planned = result(estimates.keys, estimates, deps:, verbs:, verb: :install).batches
      expect(planned.map { |b| [b.verb, b.names] }).to eq(
        [[:dependency, %w[missing]], [:upgrade, %w[outdated]], [:dependency, %w[other]]],
      )
    end

    it "splits before a slow keg-only formula only in batches upgraded, as only `brew upgrade` moves them first" do
      estimates = { "quick" => 10, "llvm" => 3000 }
      keg_only = %w[llvm]
      planned = [:upgrade, :dependency].to_h do |dependency_verb|
        verbs = estimates.keys.to_h { |name| [name, dependency_verb] }
        [dependency_verb, batches(estimates.keys, estimates, keg_only:, verbs:, verb: :install)]
      end
      expect(planned).to eq(upgrade: [%w[quick], %w[llvm]], dependency: [%w[quick llvm]])
    end

    it "rejects an unknown verb of a formula's own" do
      expect { result(%w[a], { "a" => 1 }, verbs: { "a" => :install }, verb: :install) }
        .to raise_error(ArgumentError, /install for a/)
    end
  end

  describe ".plan --last" do
    sig { returns(T::Hash[String, Numeric]) }
    def estimates
      { "a" => 10, "b" => 20, "c" => 30, "d" => 5 }
    end

    it "puts the formulae in a final batch" do
      expect(batches(%w[a b c], estimates, last: %w[a])).to eq([%w[b c], %w[a]])
    end

    it "labels batches main and last" do
      expect(result(%w[a b], estimates, last: %w[a]).batches.map(&:label)).to eq(%w[main last])
    end

    it "labels the final batch with --last" do
      expect(result(%w[a b], estimates, last: %w[a]).batches.map(&:reason)).to eq([nil, "--last"])
    end

    it "moves dependents of a --last formula with it" do
      deps = { "c" => %w[a] }
      expect(batches(%w[a b c d], estimates, deps:, last: %w[a])).to eq([%w[d b], %w[a c]])
    end

    it "moves transitive dependents with it" do
      deps = { "b" => %w[a], "c" => %w[b] }
      expect(batches(%w[a b c d], estimates, deps:, last: %w[a])).to eq([%w[d], %w[a b c]])
    end

    it "keeps a --last formula ahead of its dependent" do
      expect(batches(%w[a b], estimates, deps: { "b" => %w[a] }, last: %w[a])).to eq([%w[a b]])
    end

    it "has no main batch when everything is --last" do
      expect(result(%w[a b], estimates, last: %w[a b]).batches.map(&:label)).to eq(%w[last])
    end

    it "ignores --last names outside the set" do
      expect(batches(%w[a b], estimates, last: %w[zzz])).to eq([%w[a b]])
    end

    it "moves dependents through a formula outside the set" do
      deps = { "c" => %w[x], "x" => %w[a] }
      expect(batches(%w[a b c], estimates, deps:, last: %w[a])).to eq([%w[b], %w[a c]])
    end

    it "moves dependencies of their own verbs needed only by the final batch with it, but no named formula, " \
       "nor a dependency the main batches need" do
      estimates = { "zlib" => 5, "sqlite" => 10, "geos" => 97, "proj" => 97, "aria2" => 97, "gdal" => 97,
                    "named" => 20 }
      deps = { "aria2" => %w[zlib], "proj" => %w[sqlite], "gdal" => %w[zlib geos proj named] }
      verbs = { "zlib" => :dependency, "sqlite" => :dependency, "geos" => :dependency, "proj" => :upgrade }
      planned = result(estimates.keys, estimates, deps:, verbs:, verb: :install, last: %w[gdal]).batches
      expect(planned.map { |b| [b.label, b.reason, b.verb, b.names] }).to eq(
        [["main", nil, :dependency, %w[zlib]], ["main", nil, nil, %w[named aria2]],
         ["last", "--last", :dependency, %w[sqlite geos]], ["last", nil, :upgrade, %w[proj]],
         ["last", nil, nil, %w[gdal]]],
      )
    end

    it "applies to every verb" do
      aggregate_failures do
        [:upgrade, :install, :reinstall].each do |verb|
          expect(batches(%w[a b], estimates, last: %w[a], verb:)).to eq([%w[b], %w[a]]), "verb #{verb}"
        end
      end
    end

    it "splits before a slow keg-only formula inside the last batch" do
      estimates = { "a" => 10, "llvm" => 3000 }
      planned = result(%w[a llvm], estimates, keg_only: %w[llvm], last: %w[a llvm]).batches
      expect(planned.map { |b| [b.label, b.reason, b.names] }).to eq(
        [["last", "--last", %w[a]], ["last", "keg-only llvm", %w[llvm]]],
      )
    end
  end
end
# rubocop:enable Sorbet/BlockMethodDefinition
