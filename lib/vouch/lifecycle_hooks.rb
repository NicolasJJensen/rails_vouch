# frozen_string_literal: true

module Vouch
  # Executes lifecycle hook phases around a controller operation. The caller
  # owns the transaction and decides when successful completion is known.
  # After callbacks wait for every open joinable Active Record transaction, so
  # they never run after a savepoint that an enclosing host transaction rolls
  # back.
  module LifecycleHooks
    private

    def prepare_lifecycle_hooks(kind, *args, **options)
      execution = prepare_hooks(kind, *args, **options)
      execution.run_before!
      execution
    end

    def run_lifecycle_operation(execution)
      return false if execution.halted?

      execution.run { |environment| yield environment }
      execution.run_on!
      execution.core_ran?
    end

    def finish_lifecycle_hooks(execution, completed:)
      return unless completed && !execution.halted? && execution.core_ran?

      ActiveRecord.after_all_transactions_commit { execution.run_after! }
    end
  end
end
