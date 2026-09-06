# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/recipe_builder/recipe_builder"

class RecipeBuilderTest < Minitest::Test
  def recipe
    {
      "title" => "Chickpea skillet", "servings" => 2, "total_minutes" => 25,
      "ingredients" => [{ "name" => "Chickpeas", "quantity" => "400 g cooked" }],
      "steps" => ["Heat the chickpeas."],
      "sources" => %w[https://example.org/a https://example.org/b].map { |url| { "url" => url, "supports" => "Technique" } },
      "assumptions" => ["Adaptation: simplified for two servings."]
    }
  end

  def call_tool(name, arguments)
    TurnKit::Result.new(tool_calls: [TurnKit::ToolCall.new(id: name, name: name, arguments: arguments)])
  end

  def test_skill_context_research_review_and_json_submission
    web = Object.new
    web.define_singleton_method(:search) { |**| { "results" => [] } }
    web.define_singleton_method(:read_pages) do |urls:, **|
      { "results" => urls.map { |url| { "url" => url, "excerpts" => ["Heat cooked chickpeas."] } } }
    end
    client = FakeClient.new(
      call_tool("load_skill", { key: "building-recipes" }),
      call_tool("web_search", { objective: "Chickpeas", search_queries: ["chickpea skillet"] }),
      call_tool("read_sources", { urls: recipe["sources"].map { |source| source["url"] } }),
      call_tool("record_research_note", { note: "Use cooked chickpeas to meet the time limit." }),
      call_tool("recipe_reviewer", { task: "Review the chickpea recipe and these source excerpts." }),
      TurnKit::Result.new(text: "Use cooked chickpeas and state drained weight."),
      call_tool("submit_recipe", { recipe: recipe })
    )
    run = RecipeBuilder.run(request: "Two servings, no peanuts", model: "test-model", client: client, web: web)
    assert run.completed?, run.output_text
    assert_equal recipe, JSON.parse(run.output_text)
    assert_includes client.calls.first[:dynamic_instructions], "Two servings, no peanuts"
    refute_includes client.calls.first[:instructions], "Never claim a recipe has been kitchen-tested"
    assert_includes JSON.generate(client.calls[1][:messages]), "Never claim a recipe has been kitchen-tested"
    refute_includes client.calls.first[:dynamic_instructions], "Use cooked chickpeas to meet the time limit."
    assert_includes client.calls.last[:dynamic_instructions], "Use cooked chickpeas to meet the time limit."
    assert client.calls.all? { |call| call[:thinking] == { effort: "high" } }
    assert run.turn_records.any? { |turn| turn["agent_name"] == "recipe_reviewer" && turn["status"] == "completed" }
    assert_empty TurnKit.context_contributors
  end

  def test_submission_rejects_unread_citations
    execution = Struct.new(:tool_name, :result)
    turn = Struct.new(:tool_executions).new([
      execution.new("recipe_reviewer", { "status" => "completed" }),
      execution.new("load_skill", { "key" => "building-recipes" })
    ])
    context = Struct.new(:turn).new(turn)
    tool = RecipeBuilder::SubmitRecipe.new({ "notes" => ["Adaptation"], "sources" => {} })
    error = assert_raises(TurnKit::ToolError) { tool.call(recipe: recipe, context: context) }
    assert_includes error.message, "successfully read sources"
  end
end
