# frozen_string_literal: true

require_relative "lib/turnkit/version"

Gem::Specification.new do |spec|
  spec.name = "turnkit"
  spec.version = TurnKit::VERSION
  spec.authors = [ "Sam Couch" ]
  spec.email = [ "sam@samcouch.com" ]

  spec.summary = "Ruby/Rails agent runtime for durable AI conversations, runs, and orchestrator agents."
  spec.description = "TurnKit is a Ruby/Rails agent runtime for durable AI conversations, application runs, orchestrator agents, tool calling, skills, sub-agents, context compaction, and persistence."
  spec.homepage = "https://github.com/samuelcouch/turnkit"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = "#{spec.homepage}#readme"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["*.{md,txt}", "lib/**/*"]
  spec.require_paths = [ "lib" ]

  # No runtime dependencies. The default TurnKit::Adapters::RubyLLM adapter
  # requires the ruby_llm gem (>= 1.16); add it to your Gemfile to use it.
end
