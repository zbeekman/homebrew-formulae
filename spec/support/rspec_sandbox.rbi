# typed: strict

module RSpec
  module Core
    # RSpec's sandbox for running example groups inside an example, which the
    # `rspec-core` RBI lacks, as RSpec loads it only on
    # `require "rspec/core/sandbox"`.
    module Sandbox
      sig {
        type_parameters(:U)
          .params(block: T.proc.params(config: RSpec::Core::Configuration).returns(T.type_parameter(:U)))
          .returns(T.type_parameter(:U))
      }
      def self.sandboxed(&block); end
    end
  end
end
