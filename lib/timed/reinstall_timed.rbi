# typed: strict

module Homebrew
  module Cmd
    class ReinstallTimed
      sig { returns(Homebrew::Cmd::ReinstallTimed::Args) }
      def args; end

      # Brew generates these for its own commands only. The command takes
      # every `brew reinstall` flag, then adds `--dry-run` and
      # `Timed::Command.define_flags`'s other than `--last`. Not in `cmd/`,
      # where brew takes every file for a command. RuboCop's project index
      # only sees this tap, so it takes brew's `Reinstall` for a typo of
      # `ReinstallTimed`.
      class Args < Homebrew::Cmd::Reinstall::Args # rubocop:disable Lint/NameTypo
        sig { returns(T::Boolean) }
        def dry_run?; end

        sig { returns(T.nilable(String)) }
        def estimator; end

        sig { returns(T.nilable(T::Array[String])) }
        def exclude; end

        sig { returns(T.nilable(T::Array[String])) }
        def guess; end

        sig { returns(T.nilable(String)) }
        def llm_api_key_file; end

        sig { returns(T.nilable(String)) }
        def llm_effort; end

        sig { returns(T.nilable(T::Boolean)) }
        def llm_estimates?; end

        sig { returns(T.nilable(String)) }
        def llm_model; end

        sig { returns(T.nilable(String)) }
        def llm_provider; end

        sig { returns(T.nilable(String)) }
        def llm_timeout; end

        sig { returns(T.nilable(String)) }
        def llm_url; end

        sig { returns(T::Boolean) }
        def no_stamp_receipts?; end
      end
    end
  end
end
