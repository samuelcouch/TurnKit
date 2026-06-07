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

      def validate!(model:)
        require "ruby_llm"

        raise ModelAccessError, "model is required" if model.to_s.empty?

        configure_from_environment
        provider = provider_for(model)
        key_name = KEY_BY_PROVIDER[provider]
        return true unless key_name
        return true if ENV[key_name].to_s != "" || config_key_present?(provider)

        raise ModelAccessError, "#{key_name} is required for #{model}. Set ENV[#{key_name.inspect}] or configure RubyLLM before running TurnKit."
      end

      def chat(model:, messages:, tools:, instructions:, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
        require "ruby_llm"

        configure_from_environment

        chat = ::RubyLLM.chat(model: model)
        add_instructions(chat, instructions, model: model)
        chat.with_temperature(temperature) if temperature
        apply_thinking(chat, thinking)
        chat.with_schema(normalize_schema(output_schema)) if output_schema
        Array(tools).each { |tool| chat.with_tool(ruby_llm_tool(tool)) }
        Array(messages).each { |message| add_message(chat, message) }

        response = complete_without_tool_execution(chat)
        normalize_response(response, model: model)
      end

      private
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

        def complete_without_tool_execution(chat)
          provider = chat.instance_variable_get(:@provider)
          provider.complete(
            chat.messages,
            tools: chat.tools,
            tool_prefs: chat.tool_prefs,
            temperature: chat.instance_variable_get(:@temperature),
            model: chat.model,
            params: chat.params,
            headers: chat.headers,
            schema: chat.schema,
            thinking: chat.instance_variable_get(:@thinking)
          )
        end

        def add_message(chat, message)
          role = (message[:role] || message["role"]).to_sym
          content = message[:content] || message["content"] || ""
          chat.add_message(
            {
              role: role,
              content: content,
              tool_calls: ruby_llm_tool_calls(message[:tool_calls] || message["tool_calls"]),
              tool_call_id: message[:tool_call_id] || message["tool_call_id"]
            }.compact
          )
        end

        def add_instructions(chat, instructions, model:)
          return if instructions.nil? || instructions.empty?

          if prompt_cache_enabled? && anthropic_model?(model) && instructions.include?(SystemPrompt::CACHE_BOUNDARY)
            stable, dynamic = SystemPrompt.split_cache_boundary(instructions)
            add_system_message(chat, stable, cache: true)
            add_system_message(chat, dynamic, cache: false)
          else
            chat.with_instructions(instructions)
          end
        end

        def add_system_message(chat, content, cache: false)
          content = content.to_s.strip
          return if content.empty?

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
          require "ruby_llm"

          Class.new(::RubyLLM::Tool) do
            define_singleton_method(:name) { tool.tool_name }
            description tool.description
            params tool.input_schema

            define_method(:execute) do |**arguments|
              raise ToolError, "tools must be executed by TurnKit turns, not the RubyLLM adapter"
            end
          end
        end

        def normalize_response(response, model:)
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
            output_data: response_data(response),
            tool_calls: tool_calls,
            usage: usage,
            model: response.respond_to?(:model_id) ? response.model_id : model
          )
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
          response.respond_to?(method) ? response.public_send(method).to_i : 0
        end

        def thinking_token_value(response)
          token_value(response, :thinking_tokens).nonzero? || token_value(response, :reasoning_tokens)
        end

        def response_cost(response)
          return unless response.respond_to?(:cost)

          response.cost&.total
        end
    end
  end
end
