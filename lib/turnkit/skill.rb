# frozen_string_literal: true

require "yaml"

module TurnKit
  class Skill
    attr_reader :key, :name, :description, :content

    def self.from_file(path, key: nil, name: nil, description: "")
      content, metadata = parse_file(File.read(path))
      base = File.basename(path, File.extname(path))
      new(key: key || base, name: name || metadata["name"] || base.tr("_-", " ").split.map(&:capitalize).join(" "), description: description.to_s.empty? ? metadata["description"].to_s : description, content: content)
    end

    def self.from_directory(path, pattern: "*.md")
      Dir.glob(File.join(path, pattern)).sort.map { |file| from_file(file) }
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

    def self.parse_file(content)
      text = content.to_s
      return [ text, {} ] unless text.start_with?("---\n")

      _, frontmatter, body = text.split(/^---\s*$/, 3)
      return [ text, {} ] unless body

      [ body.sub(/\A\n/, ""), YAML.safe_load(frontmatter, permitted_classes: [ Symbol ], aliases: false) || {} ]
    rescue Psych::SyntaxError
      [ text, {} ]
    end
  end
end
