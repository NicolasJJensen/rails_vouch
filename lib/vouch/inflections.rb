# frozen_string_literal: true

# Vouch deliberately does not mutate ActiveSupport's process-wide
# inflections. Hosts may configure acronyms for their own Zeitwerk loaders;
# installing this gem must not change how unrelated constants are inferred.
