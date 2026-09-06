# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
end

desc "Run the durable reference app's E2E assertions (requires its database and workers)"
task "test:durable" do
  ruby "examples/durable_research/scenarios.rb", "all"
end

task default: :test
