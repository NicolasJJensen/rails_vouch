# frozen_string_literal: true

require_relative "../feature_base"

module Vouch
  module Generators
    class LockableGenerator < FeatureBase
      source_root File.expand_path("templates", __dir__)
      self.feature_template_name = "lockable"
      desc "Add lockout tracking and enable it on an existing authentication model."

      def configure_model
        path = File.join(destination_root, model_metadata.model_path)
        unless File.file?(path)
          say_status :skip, "#{model_metadata.model_path} not found; add authenticates_with :lockable to the model", :yellow
          return
        end

        contents = File.read(path)
        declarations = contents.scan(/authenticates_with[^\n]*(?:\n[ \t]+:[^\n]*)*/)
        wiring = +"\n"
        wiring << "  include Vouch::Authenticatable\n" unless contents.include?("include Vouch::Authenticatable")
        wiring << "  authenticates_with :lockable\n" unless declarations.any? { |line| line.match?(/:lockable\b/) }
        inject_model_code(path, model_metadata, wiring) unless wiring == "\n"
      end
    end
  end
end
