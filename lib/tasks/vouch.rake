namespace :vouch do
  desc "Verify Vouch mappings, feature columns, associations, and host contracts"
  task verify: :environment do
    # Route DSL registration is lazy in Rails applications; force it before
    # inspecting the mapping registry in a fresh task process.
    Rails.application.routes.routes
    Vouch.verify!
    puts "Vouch verification passed"
  end
end
