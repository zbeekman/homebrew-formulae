# typed: true
# frozen_string_literal: true

RSpec.describe "the spec harness", type: :system do
  it "loads Homebrew with its prefix in a temporary directory" do
    expect(HOMEBREW_PREFIX.to_s).to start_with(TEST_TMPDIR)
  end

  it "runs with a throwaway home directory" do
    expect(File.basename(Dir.home)).to start_with("homebrew-tap-specs-")
  end

  it "checks Sorbet signatures at runtime" do
    klass = Class.new do
      sig { params(number: Integer).returns(Integer) }
      define_method(:double) { |number| number * 2 }
    end
    expect { klass.new.double("1") }.to raise_error(TypeError)
  end
end
