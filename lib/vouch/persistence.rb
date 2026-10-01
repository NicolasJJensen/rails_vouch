# frozen_string_literal: true

module Vouch
  module Persistence
    class Cancelled < ActiveRecord::RecordNotSaved; end

    def self.transaction(record)
      completed = Object.new
      value = nil
      result = record.class.transaction(requires_new: true) do
        value = yield
        completed
      end
      raise Cancelled.new('Authentication persistence was cancelled', record) unless result.equal?(completed)

      value
    rescue Cancelled
      if record.persisted?
        errors = record.errors.dup
        record.reload
        record.errors.copy!(errors)
      end
      raise
    end

    # Active Record can swallow a callback's Rollback and return nil from a
    # bang write. Raising here also rolls back earlier writes in this operation.
    def self.update!(record, attributes)
      ensure_saved!(record, record.update!(attributes))
    end

    def self.save!(record)
      ensure_saved!(record, record.save!)
    end

    def self.create!(source, attributes)
      record = source.new(attributes)
      save!(record)
      record
    end

    def self.destroy!(record)
      ensure_saved!(record, record.destroy!)
    end

    def self.ensure_saved!(record, result)
      raise Cancelled.new('Authentication state was not saved', record) unless result

      result
    end
    private_class_method :ensure_saved!
  end
end
