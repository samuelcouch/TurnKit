# frozen_string_literal: true

module TurnKit
  module Adapters
    class RubyLLM < Client
      def chat(model:, messages:, tools:, instructions:, temperature: nil, thinking: nil, metadata: nil)
        require "ruby_llm"

        configure_from_environment

        chat = ::RubyLLM.chat(model: model)
        add_instructions(chat, instructions, model: model)
        chat.with_temperature(temperature) if temperature
        apply_thinking(chat, thinking)
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

        def apply_thinking(chat, thinking)
          thinking = Agent.normalize_thinking(thinking)
          chat.with_thinking(**thinking) if thinking
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
            tool.parameters.each do |param|
              param(param.fetch(:name).to_sym, type: param.fetch(:type), required: param.fetch(:required), desc: param.fetch(:description))
            end

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
            text: response.respond_to?(:content) ? response.content.to_s : response.to_s,
            tool_calls: tool_calls,
            usage: usage,
            model: response.respond_to?(:model_id) ? response.model_id : model
          )
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
