# frozen_string_literal: true

require_relative "lib/turnkit/version"

Gem::Specification.new do |spec|
  spec.name = "turnkit"
  spec.version = TurnKit::VERSION
  spec.authors = [ "Sam Couch" ]
  spec.email = [ "sam@samcouch.com" ]

  spec.summary = "Durable Ruby AI agent turns, tools, skills, and conversations."
  spec.description = "TurnKit provides a small Ruby runtime for AI agents with conversations, turns, tool calls, terminal tools, file-based skills, sub-agents, and optional Rails persistence."
  spec.homepage = "https://github.com/samcouch/turnkit"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = "#{spec.homepage}#readme"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["*.{md,txt}", "lib/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "ruby_llm", "~> 1.14"
end
