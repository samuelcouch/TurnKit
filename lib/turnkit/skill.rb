# frozen_string_literal: true

module TurnKit
  class Skill
    attr_reader :key, :name, :description, :content

    def self.from_file(path, key: nil, name: nil, description: "")
      content = File.read(path)
      base = File.basename(path, File.extname(path))
      new(key: key || base, name: name || base.tr("_-", " ").split.map(&:capitalize).join(" "), description: description, content: content)
    end

    def initialize(key:, name:, content:, description: "")
      @key = key.to_s
      @name = name.to_s
      @description = description.to_s
      @content = content.to_s
      raise ArgumentError, "key is required" if @key.empty?
      raise ArgumentError, "name is required" if @name.empty?
      raise ArgumentError, "content is required" if @content.empty?
    end
  end
end
