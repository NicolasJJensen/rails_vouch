# Non-isolated Rails Engine for Vouch.
#
# Mounts Warden middleware and optionally configures OmniAuth providers.
# The engine adds app/controllers/ to the autoload paths so the gem's
# two-layer controllers (base + thin defaults) are available to the host app.
#
module Vouch
  class Engine < Rails::Engine
    initializer "vouch.application_helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        include Vouch::ApplicationHelpers
      end
      ActiveSupport.on_load(:action_controller_api) do
        include Vouch::ApplicationHelpers
      end
    end

    # Warden middleware is installed by default. Hosts that already install
    # Warden can set `install_middleware = false` and call
    # `Vouch.configure_warden(manager)` from their middleware setup.
    initializer "vouch.warden", after: :load_config_initializers do |app|
      next unless Vouch.configuration.install_middleware

      app.config.middleware.use Warden::Manager do |manager|
        Vouch.configure_warden(manager)
      end
    end

    # Re-resolve mapping reflections after each Zeitwerk reload so association
    # objects point at the current model classes.
    # Adding new scopes in config/routes.rb still requires a restart.
    initializer "vouch.reload_mappings", after: :load_config_initializers do |app|
      app.config.to_prepare do
        Vouch.each_mapping do |mapping|
          mapping.reset_class_cache!
          mapping.resolve_reflections!
        end
      end
    end

    # Load gem locale files first so host overrides (loaded later) take precedence.
    initializer "vouch.i18n" do
      config.i18n.load_path.unshift(*Dir[root.join("config", "locales", "**", "*.{rb,yml}")])
    end
  end
end
