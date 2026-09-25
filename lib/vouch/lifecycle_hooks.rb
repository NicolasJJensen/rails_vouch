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
      result = run_hooks(:"commit_of_#{kind}", *args, **kwargs) do |env|
        core_ran = true
        operation.call(env)
      end
      core_ran ? result : false
    end

    # Runs the persistence half of a lifecycle. `commit_of_*` wraps this
    # helper and therefore runs after a successful transaction and any session
    # publication performed by its caller. Ordinary callbacks run inside the
    # transaction, where they can add writes or abort them atomically.
    def run_commit_hooks(kind, *args, **kwargs)
      committed = false

      ActiveRecord::Base.transaction(requires_new: true) do
        core_ran = false
        result = run_hooks(kind, *args, **kwargs) do |env|
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
