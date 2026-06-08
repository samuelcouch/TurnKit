# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "turnkit"

class ConversationClient < TurnKit::Client
  attr_reader :calls

  def initialize
    @calls = []
  end

  def chat(model:, messages:, tools:, instructions:, **)
    @calls << { model: model, messages: messages, tools: tools, instructions: instructions }

    text = if calls.length == 1
      "I need the duplicate charge date and payment method."
    else
      "Because the user clarified it was the business card, check business-card invoices first."
    end

    TurnKit::Result.new(text: text, model: model)
  end
end

client = ConversationClient.new
agent = TurnKit::Agent.new(
  name: "support_assistant",
  instructions: "Help support reps reason through billing issues.",
  client: client
)

conversation = agent.conversation(subject: "customer: acme@example.com")

conversation.say("The customer says they were charged twice.")
first_turn = conversation.run!

conversation.say("Follow-up: they clarified the duplicate charge was on their business card.")
second_turn = conversation.run!

puts "Use Conversation when the interaction is a durable thread."
puts
puts "conversation_id: #{conversation.id}"
puts "first_turn: #{first_turn.output_text}"
puts "second_turn: #{second_turn.output_text}"
puts "stored_messages: #{conversation.messages.length}"
puts "model_calls: #{client.calls.length}"
puts "second_call_saw_messages: #{client.calls.last.fetch(:messages).length}"
