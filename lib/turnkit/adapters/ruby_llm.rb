# frozen_string_literal: true

module TurnKit
  module Adapters
    class RubyLLM < Client
      KEY_BY_PROVIDER = {
        openai: "OPENAI_API_KEY",
        gemini: "GEMINI_API_KEY",
        anthropic: "ANTHROPIC_API_KEY",
        openrouter: "OPENROUTER_API_KEY"
      }.freeze

      def initialize(protocol: nil)
        @protocol = protocol
      end

      def validate!(model:)
        ensure_ruby_llm!
        raise ModelAccessError, "model is required" if model.to_s.empty?
        if @protocol && !::RubyLLM::Chat.method_defined?(:generate)
          raise ConfigError, "protocol selection requires RubyLLM 2.0 (currently 2.0.0.rc2)"
        end

        configure_from_environment
        provider = provider_for(model)
        key_name = KEY_BY_PROVIDER[provider]
        return true unless key_name
        return true if ENV[key_name].to_s != "" || config_key_present?(provider)

        raise ModelAccessError, "#{key_name} is required for #{model}. Set ENV[#{key_name.inspect}] or configure RubyLLM before running TurnKit."
      end

      def chat(model:, messages:, tools:, instructions:, dynamic_instructions: nil, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
        ensure_ruby_llm!
        configure_from_environment

        validate!(model: model) if @protocol
        chat = ::RubyLLM.chat(**{ model: model, protocol: @protocol }.compact)
        chat.with_provider_options(metadata: metadata.transform_values(&:to_s)) if @protocol == :responses && metadata
        add_instructions(chat, instructions, dynamic_instructions, model: model)
        chat.with_temperature(temperature) if temperature
        apply_thinking(chat, thinking)
        chat.with_schema(normalize_schema(output_schema)) if output_schema
        Array(tools).each do |tool|
          chat.respond_to?(:with_tool) ? chat.with_tool(ruby_llm_tool(tool)) : chat.with_tools(ruby_llm_tool(tool))
        end
        tool_names = {}
        Array(messages).each { |message| add_message(chat, message, provider: chat.model.provider, tool_names: tool_names) }

        response = complete_without_tool_execution(chat)
        normalize_response(response, model: model)
      rescue ConfigError
        raise
      rescue ::RubyLLM::Error, ::RubyLLM::ModelNotFoundError => error
        # Provider failures (after RubyLLM's own retries) are task failures,
        # not worker crashes to be replayed by durable reconciliation.
        raise ModelError, "#{error.class}: #{error.message}"
      end

      def paint(prompt:, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: nil, on_event: nil)
        ensure_ruby_llm!
        configure_from_environment
        image = ::RubyLLM.paint(
          prompt,
          model: model,
          provider: provider,
          assume_model_exists: assume_model_exists || false,
          size: size || "1024x1024",
          with: input_images,
          mask: mask,
          **{ (::RubyLLM::Chat.method_defined?(:generate) ? :provider_options : :params) => params || {} }
        )
        normalize_image_response(image, model: model, provider: provider, params: { "size" => size || "1024x1024" }.merge(params || {}), metadata: metadata)
      rescue ConfigError
        raise
      rescue ::RubyLLM::Error, ::RubyLLM::ModelNotFoundError => error
        raise ModelError, "#{error.class}: #{error.message}"
      end

      def view_media(media:, objective:, model:, provider: nil, output_schema: nil, params: {}, metadata: nil, on_event: nil)
        ensure_ruby_llm!
        configure_from_environment
        media_input = MediaInput.wrap(media)

        chat = ::RubyLLM.chat(model: model)
        chat.with_schema(normalize_schema(output_schema)) if output_schema
        if params && !params.empty?
          if ::RubyLLM::Chat.method_defined?(:generate)
            chat.with_provider_options(**params)
          else
            chat.with_params(**params)
          end
        end
        if ::RubyLLM::Chat.method_defined?(:generate)
          attachment = ::RubyLLM::Attachment.new(media_input.attachment_source, filename: media_input.filename)
          chat.add_message(role: :user, content: objective.to_s, attachments: [attachment])
        else
          content = ::RubyLLM::Content.new(objective.to_s)
          content.add_attachment(media_input.attachment_source, filename: media_input.filename)
          chat.add_message(role: :user, content: content)
        end

        response = complete_without_tool_execution(chat)
        normalize_media_analysis_response(response, media: media_input, model: model, provider: provider, params: params || {}, metadata: metadata)
      rescue ConfigError
        raise
      rescue ::RubyLLM::Error, ::RubyLLM::ModelNotFoundError => error
        raise ModelError, "#{error.class}: #{error.message}"
      end

      private
        def ensure_ruby_llm!
          require "ruby_llm"
        rescue LoadError
          raise ConfigError, "TurnKit::Adapters::RubyLLM requires the ruby_llm gem (>= 1.16). Add `gem \"ruby_llm\"` to your Gemfile."
        end

        def configure_from_environment
          config = ::RubyLLM.config
          config.openai_api_key ||= ENV["OPENAI_API_KEY"]
          config.gemini_api_key ||= ENV["GEMINI_API_KEY"]
          config.anthropic_api_key ||= ENV["ANTHROPIC_API_KEY"]
          config.openrouter_api_key ||= ENV["OPENROUTER_API_KEY"]
        end

        def provider_for(model)
          value = model.to_s.downcase
          return :openrouter if value.start_with?("openrouter/")
          return :anthropic if value.start_with?("anthropic/", "claude")
          return :gemini if value.start_with?("gemini/", "gemini")
          return :openai if value.start_with?("openai/", "gpt", "o1", "o3", "o4")

          nil
        end

        def config_key_present?(provider)
          value = ::RubyLLM.config.public_send("#{provider}_api_key") if ::RubyLLM.config.respond_to?("#{provider}_api_key")
          value.to_s != ""
        end

        def apply_thinking(chat, thinking)
          thinking = Agent.normalize_thinking(thinking)
          chat.with_thinking(**thinking) if thinking
        end

        def normalize_schema(schema)
          case schema
          when Hash
            normalized = schema.transform_keys(&:to_s).transform_values { |value| normalize_schema(value) }
            normalized["additionalProperties"] = false if normalized["type"] == "object" && !normalized.key?("additionalProperties")
            normalized
          when Array
            schema.map { |value| normalize_schema(value) }
          else
            schema
          end
        end

        # 2.0's public generate requests one completion without executing tools.
        # 1.16 needs its private provider_completion, guarded by a canary test.
        def complete_without_tool_execution(chat)
          return chat.generate if chat.respond_to?(:generate)
          unless chat.respond_to?(:provider_completion, true)
            raise ConfigError, "TurnKit::Adapters::RubyLLM requires ruby_llm >= 1.16 (RubyLLM::Chat#provider_completion not found)"
          end

          chat.send(:provider_completion)
        end

        def add_message(chat, message, provider: nil, tool_names: {})
          role = (message[:role] || message["role"]).to_sym
          content = message[:content] || message["content"] || ""
          kind = { "openai" => "openai_responses", "anthropic" => "anthropic", "gemini" => "gemini" }[provider.to_s]
          replay = Array(message[:provider_parts] || message["provider_parts"]).find { |part| part["kind"] == kind } if kind
          calls = ruby_llm_tool_calls(message[:tool_calls] || message["tool_calls"])
          raw_content = replay&.fetch("data")
          if raw_content && %w[anthropic gemini].include?(kind) && !::RubyLLM::Chat.method_defined?(:generate)
            content = ::RubyLLM::Content::Raw.new(raw_content)
            raw_content = nil
            if kind == "gemini"
              # 1.16 appends normalized calls after Raw content. Omit those
              # duplicates and supply names for its positional function results.
              calls&.each { |id, call| tool_names[id] = call.name }
              calls = nil
            end
          end
          call_id = message[:tool_call_id] || message["tool_call_id"]
          chat.add_message(
            {
              role: role,
              content: content,
              raw_content: raw_content,
              tool_calls: calls,
              tool_call_id: tool_names.fetch(call_id, call_id)
            }.compact
          )
        end

        def add_instructions(chat, instructions, dynamic_instructions, model:)
          stable = instructions.to_s
          dynamic = dynamic_instructions.to_s
          return if stable.empty? && dynamic.empty?

          if prompt_cache_enabled? && anthropic_model?(model) && !dynamic.empty?
            add_system_message(chat, stable, cache: true)
            add_system_message(chat, dynamic, cache: false)
          else
            chat.with_instructions([ stable, dynamic ].reject(&:empty?).join("\n\n"))
          end
        end

        def add_system_message(chat, content, cache: false)
          content = content.to_s.strip
          return if content.empty?

          if ::RubyLLM::Chat.method_defined?(:generate)
            chat.add_message(role: :system, content: content, cache_until_here: cache)
            return
          end
          if cache
            content = ::RubyLLM::Providers::Anthropic::Content.new(content, cache: true)
          end

          chat.add_message(role: :system, content: content)
        end

        def prompt_cache_enabled?
          TurnKit.prompt_cache != :off
        end

        def anthropic_model?(model)
          model.to_s.start_with?("claude")
        end

        def ruby_llm_tool_calls(tool_calls)
          return nil if tool_calls.nil? || tool_calls.empty?

          calls = tool_calls.is_a?(Hash) ? tool_calls.values : Array(tool_calls)
          calls.to_h do |tool_call|
            attrs = tool_call.respond_to?(:to_h) ? tool_call.to_h : tool_call
            attrs = attrs.transform_keys(&:to_s)
            id = attrs.fetch("id")
            [ id, ::RubyLLM::ToolCall.new(id: id, name: attrs.fetch("name"), arguments: attrs["arguments"] || {}) ]
          end
        end

        def ruby_llm_tool(tool)
          Class.new(::RubyLLM::Tool) do
            define_singleton_method(:name) { tool.tool_name }
            description tool.description
            respond_to?(:params) ? params(tool.input_schema) : parameters(tool.input_schema)

            define_method(:execute) do |**arguments|
              raise ToolError, "tools must be executed by TurnKit turns, not the RubyLLM adapter"
            end
          end
        end

        def normalize_response(response, model:)
          raw = response.raw.body if response.respond_to?(:raw) && response.raw.respond_to?(:body)
          if raw.is_a?(Hash) && raw["object"] == "response" && raw["status"] != "completed"
            raise ModelError, "OpenAI Responses #{raw['status']}: #{raw.dig('incomplete_details', 'reason')}"
          end
          tool_calls = Array(response.respond_to?(:tool_calls) ? response.tool_calls&.values : []).map do |call|
            ToolCall.new(id: call.id, name: call.name, arguments: call.arguments)
          end
          usage = Usage.new(
            input_tokens: token_value(response, :input_tokens),
            output_tokens: token_value(response, :output_tokens),
            cached_tokens: token_value(response, :cached_tokens),
            cache_write_tokens: token_value(response, :cache_creation_tokens),
            thinking_tokens: thinking_token_value(response),
            cost: response_cost(response)
          )
          Result.new(
            text: response_text(response),
            parts: response_parts(response, tool_calls: tool_calls),
            output_data: response_data(response),
            tool_calls: tool_calls,
            usage: usage,
            model: response_model(response, model)
          )
        end

        def response_parts(response, tool_calls:)
          content = response.respond_to?(:content) ? response.content : response
          parts = case content
          when Array
            content.map { |part| normalize_provider_part(part) }
          when Hash
            [ { "type" => "text", "text" => content.to_json } ]
          else
            text = content.to_s
            text.empty? ? [] : [ { "type" => "text", "text" => text } ]
          end.compact
          raw = response.raw.body if response.respond_to?(:raw) && response.raw.respond_to?(:body)
          if raw.is_a?(Hash) && raw["object"] == "response"
            parts << { "type" => "provider", "kind" => "openai_responses", "data" => raw.fetch("output") }
          elsif raw.is_a?(Hash) && raw["type"] == "message" && raw["role"] == "assistant"
            parts << { "type" => "provider", "kind" => "anthropic", "data" => raw.fetch("content") }
          elsif raw.is_a?(Hash) && raw.dig("candidates", 0, "content", "parts")
            parts << { "type" => "provider", "kind" => "gemini", "data" => raw.dig("candidates", 0, "content", "parts") }
          end
          parts + Array(tool_calls).map { |call| { "type" => "tool_call", "id" => call.id, "name" => call.name, "arguments" => call.arguments } }
        end

        def normalize_provider_part(part)
          attrs = part.respond_to?(:to_h) ? part.to_h.transform_keys(&:to_s) : nil
          return { "type" => "text", "text" => part.to_s } unless attrs

          case attrs["type"].to_s
          when "text", "output_text"
            { "type" => "text", "text" => attrs["text"] || attrs["content"].to_s }
          when "thinking", "reasoning"
            { "type" => "thinking", "text" => attrs["text"] || attrs["content"].to_s, "signature" => attrs["signature"], "redacted" => attrs["redacted"] || false }.compact
          else
            { "type" => "provider", "kind" => attrs["type"].to_s, "data" => attrs }
          end
        end

        def response_text(response)
          content = response.respond_to?(:content) ? response.content : response
          content.is_a?(Hash) || content.is_a?(Array) ? content.to_json : content.to_s
        end

        def response_data(response)
          content = response.respond_to?(:content) ? response.content : nil
          return content if content.is_a?(Hash) || content.is_a?(Array)
          return nil unless content.is_a?(String)

          JSON.parse(content)
        rescue JSON::ParserError
          nil
        end

        def token_value(response, method)
          if response.respond_to?(method)
            value = response.public_send(method).to_i
            raw = response.raw.body if response.respond_to?(:raw) && response.raw.respond_to?(:body)
            native = raw.is_a?(Hash) && (raw["candidates"] || raw["type"] == "message")
            # Native 1.16 providers also include thinking in their output count.
            return native && method == :output_tokens ? value - thinking_token_value(response) : value
          end
          return 0 unless response.respond_to?(:tokens)

          key = { input_tokens: :input, output_tokens: :output, cached_tokens: :cache_read,
            cache_creation_tokens: :cache_write, thinking_tokens: :thinking, reasoning_tokens: :thinking }.fetch(method)
          value = response.tokens.public_send(key).to_i
          # RubyLLM 2.0 includes thinking in output; TurnKit buckets are additive.
          method == :output_tokens ? value - response.tokens.thinking.to_i : value
        end

        def response_model(response, fallback)
          return response.model if response.respond_to?(:model)
          response.respond_to?(:model_id) ? response.model_id : fallback
        end

        def thinking_token_value(response)
          token_value(response, :thinking_tokens).nonzero? || token_value(response, :reasoning_tokens)
        end

        def response_cost(response)
          return unless response.respond_to?(:cost)

          response.cost&.total
        end

        def normalize_image_response(image, model:, provider:, params:, metadata:)
          usage = Usage.new(
            input_tokens: image_usage_value(image, "input_tokens"),
            output_tokens: image_usage_value(image, "output_tokens"),
            cost: response_cost(image)
          )
          part = ImageResult.new(
            url: image.respond_to?(:url) ? image.url : nil,
            data: image.respond_to?(:data) ? image.data : nil,
            mime_type: image.respond_to?(:mime_type) ? image.mime_type : nil,
            revised_prompt: image.respond_to?(:revised_prompt) ? image.revised_prompt : nil,
            model: response_model(image, model),
            provider: provider&.to_s,
            usage: usage,
            params: params,
            metadata: metadata || {}
          ).to_h.merge("type" => "image")

          Result.new(parts: [ part ], usage: usage, model: part["model"], output_data: { "type" => "image", "images" => [ part ] })
        end

        def normalize_media_analysis_response(response, media:, model:, provider:, params:, metadata:)
          usage = Usage.new(
            input_tokens: token_value(response, :input_tokens),
            output_tokens: token_value(response, :output_tokens),
            cached_tokens: token_value(response, :cached_tokens),
            cache_write_tokens: token_value(response, :cache_creation_tokens),
            thinking_tokens: thinking_token_value(response),
            cost: response_cost(response)
          )
          part = MediaAnalysisResult.new(
            text: response_text(response),
            data: response_data(response),
            model: response_model(response, model),
            provider: provider&.to_s,
            usage: usage,
            params: params,
            media: media.to_h,
            metadata: metadata || {}
          ).to_h.merge("type" => "media_analysis")

          Result.new(parts: [ part ], usage: usage, model: part["model"], output_data: { "type" => "media_analysis", "media_analyses" => [ part ] })
        end

        def image_usage_value(image, key)
          return image.tokens.public_send(key == "input_tokens" ? :input : :output).to_i if image.respond_to?(:tokens)
          usage = image.respond_to?(:usage) ? image.usage || {} : {}
          (usage[key] || usage[key.to_sym]).to_i
        end
    end
  end
end
