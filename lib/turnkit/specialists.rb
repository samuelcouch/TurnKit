# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "pathname"
require "uri"

module TurnKit
  # Small, composable factories for common specialist agents. The returned
  # objects are ordinary Agent and Tool instances and may be further configured
  # or subclassed by applications.
  module Specialists
    ORACLE_INSTRUCTIONS = <<~TEXT.strip
      Act as an expert advisor. Inspect the supplied read-only sources before
      drawing conclusions. Complete the requested analysis, distinguish facts
      from recommendations, state material uncertainty, and return the full
      result. Never claim to have changed application state.
    TEXT

    LIBRARIAN_INSTRUCTIONS = <<~TEXT.strip
      Research the configured external GitHub repository using the repository
      tool. Read the relevant files and history, not merely repository titles.
      Return a complete answer with source URLs for factual claims and identify
      the ref or comparison used. Do not imply that repository state was changed.
    TEXT

    PAINTER_INSTRUCTIONS = <<~TEXT.strip
      Create or edit the requested image with the image tool. Translate the task
      into a precise visual prompt, pass all relevant reference images and mask,
      and return the generated image artifact. Generation is permitted only when
      the application authorization gate allows the tool call.
    TEXT

    class ReadOnlyTool < Tool
      recovery :replay_safe
      def self.read_only? = true
      def read_only? = true
    end

    class ReadFile < ReadOnlyTool
      tool_name "read_file"
      description "Read a UTF-8 text file beneath the configured root."
      parameter :path, :string, required: true, description: "Path relative to the configured root."

      def initialize(root:, max_bytes: 100_000)
        @root = Pathname(root).expand_path.realpath
        @max_bytes = Integer(max_bytes)
      end

      def call(path:, context:)
        target = confined_path(path)
        raise ToolError, "not a file: #{path}" unless target.file?
        raise ToolError, "file exceeds #{@max_bytes} bytes" if target.size > @max_bytes

        { "path" => target.relative_path_from(@root).to_s, "content" => target.binread.force_encoding(Encoding::UTF_8) }
      rescue Errno::ENOENT, Errno::EACCES, ArgumentError => error
        raise ToolError, "cannot read #{path}: #{error.message}"
      end

      private

      def confined_path(path)
        candidate = @root.join(path.to_s).realpath
        prefix = @root.to_s + File::SEPARATOR
        raise ToolError, "path is outside configured root" unless candidate == @root || candidate.to_s.start_with?(prefix)

        candidate
      end
    end

    class GitHubRepository < ReadOnlyTool
      tool_name "github_repository_read"
      description "Read files, repository metadata, commits, diffs, and issues from one configured GitHub repository."
      parameter :operation, :enum, required: true, enum: %w[repository file history diff issues issue comments]
      parameter :path, :string, description: "Repository-relative file path (file operation)."
      parameter :ref, :string, description: "Branch, tag, or commit for file/history operations."
      parameter :base, :string, description: "Base ref for a diff."
      parameter :head, :string, description: "Head ref for a diff."
      parameter :number, :integer, description: "Issue number."
      parameter :state, :enum, enum: %w[open closed all], default: "open"
      parameter :page, :integer, default: 1

      API_HOST = "api.github.com"

      def initialize(repository:, client: nil, token: ENV["GITHUB_TOKEN"])
        @repository = normalize_repository(repository)
        @client = client || method(:http_get)
        @token = token.to_s
      end

      def call(operation:, path: nil, ref: nil, base: nil, head: nil, number: nil, state: "open", page: 1, context:)
        endpoint, query = endpoint_for(operation, path: path, ref: ref, base: base, head: head,
          number: number, state: state, page: page)
        uri = URI::HTTPS.build(host: API_HOST, path: "/repos/#{@repository}#{endpoint.empty? ? '' : '/' + endpoint}", query: URI.encode_www_form(query))
        response = @client.call(uri: uri, headers: headers)
        status, body = unpack_response(response)
        raise ToolError, "GitHub API returned HTTP #{status}" unless status.between?(200, 299)

        data = JSON.parse(body)
        if operation == "file" && data.is_a?(Hash) && data["encoding"] == "base64"
          data = data.merge("content" => Base64.decode64(data.fetch("content")))
        end
        { "repository" => @repository, "operation" => operation, "source" => source_url(operation, data, uri), "data" => data }
      rescue JSON::ParserError => error
        raise ToolError, "invalid GitHub API response: #{error.message}"
      end

      private

      def normalize_repository(value)
        repository = value.to_s
        raise ArgumentError, "repository must be owner/name" unless repository.match?(%r{\A[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9_.-]+\z}) && !%w[. ..].include?(repository.split('/').last)

        repository
      end

      def endpoint_for(operation, path:, ref:, base:, head:, number:, state:, page:)
        case operation
        when "repository" then [ "", {} ]
        when "file"
          raise ToolValidationError, "path is required for file" if path.to_s.empty?
          raise ToolValidationError, "invalid repository path" if path.to_s.split("/").include?("..") || path.to_s.start_with?("/")
          [ "contents/#{path.to_s.split('/').map { |part| escape_segment(part) }.join('/')}", compact_query(ref: ref) ]
        when "history" then [ "commits", compact_query(sha: ref, path: path, page: page, per_page: 30) ]
        when "diff"
          raise ToolValidationError, "base and head are required for diff" if base.to_s.empty? || head.to_s.empty?
          [ "compare/#{escape_segment(base)}...#{escape_segment(head)}", {} ]
        when "issues" then [ "issues", compact_query(state: state, page: page, per_page: 30) ]
        when "issue"
          raise ToolValidationError, "number is required for issue" unless number
          [ "issues/#{Integer(number)}", {} ]
        when "comments"
          raise ToolValidationError, "positive issue number is required" unless number && number.positive?
          [ "issues/#{number}/comments", compact_query(page: page, per_page: 30) ]
        else raise ToolValidationError, "unknown operation: #{operation}"
        end
      end

      def escape_segment(value) = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
      def compact_query(**values) = values.reject { |_key, value| value.nil? || value.to_s.empty? }

      def headers
        result = { "Accept" => "application/vnd.github+json", "User-Agent" => "TurnKit" }
        result["Authorization"] = "Bearer #{@token}" unless @token.empty?
        result
      end

      def http_get(uri:, headers:)
        raise ToolError, "unsafe GitHub API endpoint" unless uri.is_a?(URI::HTTPS) && uri.host == API_HOST && uri.port == 443

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 45) { |http| http.get(uri.request_uri, headers) }
        # Redirects are deliberately not followed, preventing credentials from
        # being forwarded to a different endpoint.
        [ response.code.to_i, response.body.to_s ]
      end

      def unpack_response(response)
        return [ Integer(response[0]), response[1].to_s ] if response.is_a?(Array) && response.length == 2
        return [ Integer(response.code), response.body.to_s ] if response.respond_to?(:code) && response.respond_to?(:body)

        raise ToolError, "GitHub client must return [status, body] or an HTTP response"
      end

      def source_url(operation, data, uri)
        return data["html_url"] if data.is_a?(Hash) && data["html_url"].to_s.start_with?("https://github.com/")
        return data.first["html_url"] if data.is_a?(Array) && data.first.is_a?(Hash) && data.first["html_url"].to_s.start_with?("https://github.com/")

        uri.to_s
      end
    end

    class PaintImage < ImageTool
      tool_name "paint_image"
      description "Generate or edit an image after application authorization."
      parameter :prompt, :string, required: true
      parameter :reference_images, :array, default: [], items: :string
      parameter :mask, :string
      terminal! { |result| JSON.generate(result) }

      def initialize(model:, authorization:, provider: nil, size: nil, params: {}, max_reference_images: nil)
        raise ArgumentError, "authorization must be callable" unless authorization.respond_to?(:call)
        @image_model, @authorization, @provider, @size = model, authorization, provider, size
        @params, @max_reference_images = params, max_reference_images
      end

      def call(prompt:, reference_images: [], mask: nil, context:)
        references = Array(reference_images)
        if @max_reference_images && references.length > Integer(@max_reference_images)
          raise ToolValidationError, "reference_images exceeds configured limit of #{@max_reference_images}"
        end
        request = { prompt: prompt, model: @image_model, provider: @provider, size: @size,
          input_images: references, mask: mask, params: @params }
        raise ToolError, "image generation was not authorized" unless @authorization.call(request.dup, context: context) == true

        image = context.turn.paint(request.delete(:prompt), **request, metadata: { "specialist" => "painter" })
        message = context.turn.conversation.messages.reverse.find(&:image?)
        { "conversation_id" => context.turn.conversation.id, "image_message_id" => message.id,
          "image" => image.to_h.reject { |key, _| key == "data" } }
      end
    end

    module_function

    def oracle(model:, tools: nil, root: Dir.pwd, client: nil, instructions: nil, **agent_options)
      require_model!(model)
      configured = tools.nil? ? [ ReadFile.new(root: root) ] : Array(tools)
      validate_read_only!(configured + skill_tools(agent_options))
      raise ArgumentError, "read-only specialists cannot delegate to unchecked subagents" if Array(agent_options[:sub_agents]).any?
      Agent.new(name: "oracle", description: "Read-only expert analysis and advice.", model: model,
        tools: configured, client: client, instructions: combine(ORACLE_INSTRUCTIONS, instructions), **agent_options, inherit_globals: false)
    end

    def librarian(repository:, model:, client: nil, github_client: nil, token: ENV["GITHUB_TOKEN"], tools: [], instructions: nil, **agent_options)
      require_model!(model)
      repository_tool = GitHubRepository.new(repository: repository, client: github_client, token: token)
      validate_read_only!(Array(tools) + skill_tools(agent_options))
      raise ArgumentError, "read-only specialists cannot delegate to unchecked subagents" if Array(agent_options[:sub_agents]).any?
      Agent.new(name: "librarian", description: "Source-backed research in an external GitHub repository.", model: model,
        tools: [ repository_tool, *Array(tools) ], client: client,
        instructions: combine(LIBRARIAN_INSTRUCTIONS, instructions), **agent_options, inherit_globals: false)
    end

    def painter(model:, image_model:, authorization:, client: nil, tools: [], instructions: nil, provider: nil, size: nil,
      params: {}, max_reference_images: nil, **agent_options)
      require_model!(model)
      require_model!(image_model)
      image_tool = PaintImage.new(model: image_model, authorization: authorization, provider: provider, size: size,
        params: params, max_reference_images: max_reference_images)
      Agent.new(name: "painter", description: "Authorized image generation and editing.", model: model,
        tools: [ image_tool, *Array(tools) ], client: client,
        instructions: combine(PAINTER_INSTRUCTIONS, instructions), **agent_options, inherit_globals: false)
    end

    def skill_tools(options)
      (Array(options[:skills]) + Array(options[:available_skills])).flat_map(&:tools)
    end
    private_class_method :skill_tools

    def validate_read_only!(tools)
      invalid = tools.reject { |tool| tool.respond_to?(:read_only?) && tool.read_only? == true }
      raise ArgumentError, "read-only specialist tools must explicitly report read_only? == true" if invalid.any?
    end
    private_class_method :validate_read_only!

    def require_model!(model)
      raise ArgumentError, "model is required" if model.nil? || model.to_s.empty?
    end
    private_class_method :require_model!

    def combine(base, extra) = [ base, extra.to_s.strip ].reject(&:empty?).join("\n\n")
    private_class_method :combine
  end
end
