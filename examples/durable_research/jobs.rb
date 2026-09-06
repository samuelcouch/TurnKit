# frozen_string_literal: true

require_relative "app"
require "solid_queue/cli"
SolidQueue::Cli.start(ARGV)
