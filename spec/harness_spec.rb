# typed: true
# frozen_string_literal: true

module HarnessSpec
  class SigProbe
    sig { params(number: Integer).returns(Integer) }
    def double(number) = number * 2
  end
end

RSpec.describe "the spec harness", type: :system do
  it "loads Homebrew with its prefix in a temporary directory" do
    expect(HOMEBREW_PREFIX.to_s).to start_with(TEST_TMPDIR)
  end

  it "runs with a throwaway home directory" do
    expect(File.basename(Dir.home)).to start_with("homebrew-tap-specs-")
  end

  it "checks Sorbet signatures at runtime" do
    not_a_number = T.let("1", T.untyped) # hides the mistake from the static check
    expect { HarnessSpec::SigProbe.new.double(not_a_number) }.to raise_error(TypeError)
  end
end
