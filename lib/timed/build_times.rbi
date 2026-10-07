# typed: strict

module Homebrew
  module Cmd
    class BuildTimes
      class HistogramSubcommand
        # Brew generates these for its own subcommands only; the options are
        # those of the `subcommand_args` block in `cmd/build-times.rb`.
        sig { returns(T.all(Homebrew::CLI::Args, Homebrew::Cmd::BuildTimes::HistogramSubcommand::Args)) }
        def args; end

        module Args
          sig { returns(T::Boolean) }
          def builds?; end

          sig { returns(T::Boolean) }
          def linear?; end

          sig { returns(T::Boolean) }
          def poured?; end

          sig { returns(T::Boolean) }
          def smooth?; end
        end
      end

      class StatsSubcommand
        # Brew generates these for its own subcommands only; the options are
        # those of the `subcommand_args` block in `cmd/build-times.rb`.
        sig { returns(T.all(Homebrew::CLI::Args, Homebrew::Cmd::BuildTimes::StatsSubcommand::Args)) }
        def args; end

        module Args
          sig { returns(T.nilable(T.any(String, TrueClass))) }
          def json; end

          sig { returns(T::Boolean) }
          def reverse?; end

          sig { returns(T.nilable(String)) }
          def sort; end
        end
      end
    end
  end
end
