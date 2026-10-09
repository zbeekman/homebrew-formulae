# typed: strict

module Homebrew
  module Cmd
    class UpgradeTimed
      sig { returns(Homebrew::Cmd::UpgradeTimed::Args) }
      def args; end

      # Brew generates these for its own commands only. The command takes
      # every `brew upgrade` flag, then adds `Timed::Command.define_flags`'s.
      # Not in `cmd/`, where brew takes every file for a command. RuboCop's
      # project index only sees this tap, so it takes brew's `UpgradeCmd` for
      # a typo of `UpgradeTimed`.
      class Args < Homebrew::Cmd::UpgradeCmd::Args # rubocop:disable Lint/NameTypo
        sig { returns(T.nilable(String)) }
        def estimator; end

        sig { returns(T.nilable(T::Array[String])) }
        def exclude; end

        sig { returns(T.nilable(T::Array[String])) }
        def guess; end

        sig { returns(T.nilable(T::Array[String])) }
        def last; end

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
