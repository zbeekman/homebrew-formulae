# typed: true
# frozen_string_literal: true

# Bottled formulae whose bottle manifests are never downloaded, for specs
# that `include` this.
module TimedBottleHelper
  extend T::Helpers

  requires_ancestor { RSpec::Mocks::ExampleMethods }

  # Gives `klass`, a formula class being defined, a bottle for this computer.
  sig { params(klass: T.class_of(Formula)).void }
  def self.bottle(klass)
    klass.bottle do
      T.bind(self, BottleSpecification)
      sha256 cellar: :any, Utils::Bottles.tag.to_sym => "a" * 64
    end
  end

  # Stops brew downloading the manifest of `formula`'s bottle, which it reads
  # the bottle's tab from: there is no manifest to queue, and fetching the tab
  # does nothing. The tab is empty or, given `bottle_deps`, like brew's, empty
  # until the tab is fetched, then lists them with the version each needs.
  sig { params(formula: Formula, bottle_deps: T.nilable(T::Hash[String, String])).void }
  def stub_bottle_manifest(formula, bottle_deps: nil)
    allow(formula.bottle).to receive(:github_packages_manifest_resource).and_return(nil)
    fetches = []
    allow(formula.bottle).to receive(:fetch_tab) { fetches << :fetched }
    return if bottle_deps.nil?

    runtime_dependencies = bottle_deps.map do |dep, version|
      { "full_name" => dep, "version" => version, "revision" => 0 }
    end
    allow(formula.bottle).to receive(:tab_attributes) do
      fetches.empty? ? {} : { "runtime_dependencies" => runtime_dependencies }
    end
  end
end
