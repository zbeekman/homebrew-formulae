# typed: strict

module Homebrew
  module Cmd
    class BuildTimes
      class StatsSubcommand
        # Brew generates these for its own subcommands only; the options are
        # those of the `subcommand_args` block in `cmd/build-times.rb`.
        sig { returns(T.all(Homebrew::CLI::Args, Homebrew::Cmd::BuildTimes::StatsSubcommand::Args)) }
        def args; end

        module Args
          sig { returns(T::Boolean) }
          def reverse?; end

          sig { returns(T.nilable(String)) }
          def sort; end
        end
      end
    end
  end
end
