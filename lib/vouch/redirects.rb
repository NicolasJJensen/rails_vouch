# frozen_string_literal: true

module Vouch
  module Redirects
    extend ActiveSupport::Concern

    protected

    def after_sign_in_path_for(_identity = nil, scope: nil)
      root_path
    end

    def after_sign_up_path_for(_identity = nil, scope: nil)
      root_path
    end

    def after_sign_out_path_for(scope: nil)
      scope ||= auth_scope_name if respond_to?(:auth_scope_name, true)
      scope ||= Vouch.single_registered_scope
      mapping = Vouch.mapping_for(scope)
      public_send(:"new_#{mapping.helper_prefix}_session_path")
    end
  end
end
