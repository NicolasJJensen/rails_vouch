# frozen_string_literal: true

module Vouch
  module LifecycleHooks
    private

    def run_authentication_hooks(kind, *args, **kwargs, &operation)
      with_authentication_connection do |connection|
        transaction = connection.current_transaction
        if transaction.open? && transaction.joinable?
          raise Vouch::ConfigurationError,
            "Authentication lifecycle hooks cannot run inside an existing joinable transaction"
        end

        operation_completed = false
        operation_result = nil
        run_hooks(:"commit_of_#{kind}", *args, **kwargs) do |env|
          operation_result = operation.call(env)
          operation_completed = true
          operation_result
        end
        operation_completed ? operation_result : false
      end
    end

    # Runs the persistence half of a lifecycle. `commit_of_*` wraps this
    # helper and therefore runs after a successful transaction and any session
    # publication performed by its caller. Ordinary callbacks run inside the
    # transaction, where they can add writes or abort them atomically.
    def run_commit_hooks(kind, *args, **kwargs)
      committed = false

      with_authentication_connection do |connection|
        connection.transaction(requires_new: true) do |transaction|
          core_ran = false
          result = run_hooks(kind, *args, **kwargs) do |env|
            core_ran = true
            yield env
          end

          raise ActiveRecord::Rollback unless core_ran && result

          transaction.after_commit { committed = true }
        end
      end

      committed
    end

    def with_authentication_connection(&block)
      ActiveRecord::Base.connected_to(role: ActiveRecord.writing_role) do
        auth_mapping.account_class.with_connection(&block)
      end
    end
  end
end
