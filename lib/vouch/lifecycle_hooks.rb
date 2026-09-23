# frozen_string_literal: true

module Vouch
  module LifecycleHooks
    private

    def run_authentication_hooks(kind, *args, **kwargs, &operation)
      transaction = ActiveRecord::Base.connection.current_transaction
      if transaction.open? && transaction.joinable?
        raise Vouch::ConfigurationError,
          "Authentication lifecycle hooks cannot run inside an existing joinable transaction"
      end

      core_ran = false
      result = run_hooks(kind, *args, **kwargs) do |env|
        core_ran = true
        operation.call(env)
      end
      core_ran ? result : false
    end

    # Run the transactional half of a lifecycle. The outer lifecycle hook is
    # deliberately outside this transaction so its before callbacks can make
    # decisions without observing a persistence transaction. A callback that
    # cancels, or an around callback that does not yield, leaves `core_ran`
    # false and rolls the transaction back.
    def run_commit_hooks(kind, *args, **kwargs)
      committed = false

      ActiveRecord::Base.transaction(requires_new: true) do
        core_ran = false
        result = run_hooks(:"commit_of_#{kind}", *args, **kwargs) do |env|
          core_ran = true
          yield env
        end

        raise ActiveRecord::Rollback unless core_ran && result

        committed = true
      end

      committed
    end
  end
end
