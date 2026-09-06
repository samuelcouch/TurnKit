# frozen_string_literal: true

require_relative "test_helper"
require_relative "background_test"

DATABASE_URL = ENV["TURNKIT_TEST_DATABASE_URL"]

if DATABASE_URL
  require "active_record"
  require "erb"

  ActiveRecord::Base.establish_connection(DATABASE_URL)

  module TurnKitDatabaseModels
    class Conversation < ActiveRecord::Base; end
    class Turn < ActiveRecord::Base; end
    class Message < ActiveRecord::Base; end
    class ToolExecution < ActiveRecord::Base; end
    class Delivery < ActiveRecord::Base; end
    class Wait < ActiveRecord::Base; end
  end

  class BackgroundDatabaseTest < BackgroundTest
    PREFIX = "turnkit_test"
    MODELS = TurnKitDatabaseModels.constants.map { |name| TurnKitDatabaseModels.const_get(name) }.freeze

    class << self
      def startup
        template = File.read(File.expand_path("../lib/generators/turnkit/install/templates/create_turnkit_tables.rb", __dir__))
        context = Object.new
        context.define_singleton_method(:table_prefix) { PREFIX }
        migration_source = ERB.new(template).result(context.instance_eval { binding })
        Object.class_eval(migration_source)
        ActiveRecord::Migration.verbose = false
        # Rebuild only our namespaced tables so this run always verifies the
        # current generator rather than accepting schema left by an older run.
        %w[waits deliveries tool_executions messages turns conversations].each do |suffix|
          table = ActiveRecord::Base.connection.quote_table_name("#{PREFIX}_#{suffix}")
          ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{table} CASCADE")
        end
        CreateTurnkitTables.migrate(:up)

        TurnKitDatabaseModels::Conversation.table_name = "#{PREFIX}_conversations"
        TurnKitDatabaseModels::Turn.table_name = "#{PREFIX}_turns"
        TurnKitDatabaseModels::Message.table_name = "#{PREFIX}_messages"
        TurnKitDatabaseModels::ToolExecution.table_name = "#{PREFIX}_tool_executions"
        TurnKitDatabaseModels::Delivery.table_name = "#{PREFIX}_deliveries"
        TurnKitDatabaseModels::Wait.table_name = "#{PREFIX}_waits"
        MODELS.each(&:reset_column_information)
      end
    end

    startup

    def setup
      super
      # These are dedicated, prefix-scoped test tables; never touch any other table.
      ActiveRecord::Base.connection.execute("TRUNCATE #{MODELS.map { |model| ActiveRecord::Base.connection.quote_table_name(model.table_name) }.join(', ')} RESTART IDENTITY")
      @store = TurnKit::ActiveRecordStore.new(
        conversation_class: "TurnKitDatabaseModels::Conversation",
        turn_class: "TurnKitDatabaseModels::Turn",
        message_class: "TurnKitDatabaseModels::Message",
        tool_execution_class: "TurnKitDatabaseModels::ToolExecution",
        delivery_class: "TurnKitDatabaseModels::Delivery",
        wait_class: "TurnKitDatabaseModels::Wait"
      )
      TurnKit.store = @store
      TurnKit.job_dispatcher = ->(id) { @jobs << id }
      @agent = TurnKit.register(TurnKit::Agent.new(name: "database-test-agent", model: "test-model", store: @store))
    end

    def teardown
      TurnKit.job_dispatcher = nil
      ActiveRecord::Base.connection_handler.clear_active_connections!
      super
    end

    def test_concurrent_claim_of_one_turn_returns_one_token
      conversation = create_conversation
      turn = create_turn(conversation, submitted: true)

      claims = concurrently(2) { TurnKit::Background.claim(@store, turn) }

      assert_equal 1, claims.compact.length
      assert_equal claims.compact.first.fetch("claim_token"), @store.load_turn(turn.fetch("id")).fetch("claim_token")
    end

    def test_concurrent_claims_in_one_conversation_allow_only_one_running_turn
      conversation = create_conversation
      turns = 2.times.map { create_turn(conversation, submitted: true) }

      claims = concurrently(2) { |index| TurnKit::Background.claim(@store, turns.fetch(index)) }

      assert_equal 1, claims.compact.length
      assert_equal 1, @store.list_turns(conversation_id: conversation.fetch("id")).count { |row| row["status"] == "running" }
    end

    def test_simultaneous_delivery_is_idempotent_and_submits_one_continuation
      source = create_conversation
      destination = create_conversation
      delivery = @store.create_delivery("source_conversation_id" => source.fetch("id"), "destination_conversation_id" => destination.fetch("id"), "key" => unique_id("delivery"), "payload" => { "text" => "hello" })

      concurrently(2) { TurnKit::Background.deliver(delivery, store: @store) }

      messages = @store.list_messages(destination.fetch("id"))
      turns = @store.list_turns(conversation_id: destination.fetch("id"))
      assert_equal 1, messages.count { |message| message.dig("metadata", "delivery_id") == delivery.fetch("id") }
      assert_equal 1, turns.count { |turn| turn["submitted_at"] }
    end

    def test_delivery_transaction_rolls_back_message_and_delivery_when_update_fails
      source = create_conversation
      destination = create_conversation
      delivery = @store.create_delivery("source_conversation_id" => source.fetch("id"), "destination_conversation_id" => destination.fetch("id"), "key" => unique_id("delivery"), "payload" => { "text" => "hello" })
      failing_store = @store.dup
      failing_store.define_singleton_method(:update_delivery) { |_id, _attributes| raise "injected failure" }

      error = assert_raises(RuntimeError) { TurnKit::Background.deliver(delivery, store: failing_store) }
      assert_equal "injected failure", error.message
      assert_empty @store.list_messages(destination.fetch("id"))
      assert_nil @store.load_delivery(delivery.fetch("id"))["delivered_at"]
      assert_empty @store.list_turns(conversation_id: destination.fetch("id"))
    end

    def test_revoked_execution_store_cannot_write
      conversation = create_conversation
      turn = create_turn(conversation, submitted: true)
      claimed = TurnKit::Background.claim(@store, turn)
      execution_store = TurnKit::ExecutionStore.new(@store, turn_id: turn.fetch("id"), token: claimed.fetch("claim_token"), conversation_id: conversation.fetch("id"))
      @store.update_turn(turn.fetch("id"), claim_token: unique_id("replacement"))

      assert_raises(TurnKit::LostClaim) { execution_store.append_message("conversation_id" => conversation.fetch("id"), "role" => "assistant", "kind" => "text", "text" => "late") }
      assert_raises(TurnKit::LostClaim) { execution_store.update_turn(turn.fetch("id"), status: "completed") }
      assert_raises(TurnKit::LostClaim) { execution_store.claim_turn(turn.fetch("id"), from: "running", to: "completed") }
      assert_empty @store.list_messages(conversation.fetch("id"))
      assert_equal "running", @store.load_turn(turn.fetch("id"))["status"]
    end

    def test_active_job_submits_ids_and_executes_the_registered_agent
      require "turnkit/job"
      previous = TurnKit::Job.queue_adapter
      TurnKit::Job.queue_adapter = :test
      TurnKit.job_dispatcher = nil
      run = register("job-worker").run("work", async: true).perform_later
      assert_equal [run.id], TurnKit::Job.queue_adapter.enqueued_jobs.last.fetch(:args)
      TurnKit::Job.perform_now(run.id)
      assert run.reload.completed?
    ensure
      TurnKit::Job.queue_adapter = previous if previous
    end

    def test_job_signals_wait_for_outer_commit_and_are_discarded_on_rollback
      agent = register("transaction-worker")
      run = nil
      ActiveRecord::Base.transaction do
        run = agent.run("work", async: true).perform_later
        assert @jobs.empty?
      end
      assert_equal run.id, @jobs.pop
      ActiveRecord::Base.transaction do
        agent.run("rolled back", async: true).perform_later
        assert @jobs.empty?
        raise ActiveRecord::Rollback
      end
      assert @jobs.empty?
      assert_equal 1, @store.list_submitted_turns.length
    end

    def test_recovery_after_an_actual_worker_process_is_killed
      tool = CountingTool.new
      client = FakeClient.new(calls(["effect", "counting", {}]))
      agent = register("process-worker", client: client, tools: [tool], on_event: ->(event) {
        Process.kill("KILL", Process.pid) if event.type == "model.completed"
      })
      run = agent.run("work", async: true).perform_later
      pid = fork do
        ActiveRecord::Base.establish_connection(DATABASE_URL)
        TurnKit::Background.perform(run.id)
        exit! 1
      end
      _, status = Process.wait2(pid)
      assert status.signaled?
      assert_equal Signal.list.fetch("KILL"), status.termsig
      assert_equal "tools", @store.load_turn(run.id).dig("options", "state", "phase")
      replacement_client = FakeClient.new(TurnKit::Result.new(text: "recovered"))
      register("process-worker", client: replacement_client, tools: [tool])
      expire(run)
      TurnKit::Background.reconcile
      drain_jobs
      assert run.reload.completed?
      assert_equal "recovered", run.output_text
      assert_equal 1, tool.calls
      assert_equal 1, replacement_client.calls.length
    end

    def test_upgrade_generator_preserves_existing_turns_and_is_reversible
      require "tmpdir"
      require "generators/turnkit/upgrade_generator"
      connection = ActiveRecord::Base.connection
      connection.create_table(:turnkit_upgrade_test_turns) { |table| table.string :uid; table.string :status; table.timestamps }
      connection.execute("INSERT INTO turnkit_upgrade_test_turns (uid, status, created_at, updated_at) VALUES ('existing', 'pending', NOW(), NOW())")
      Dir.mktmpdir do |directory|
        generator = TurnKit::Generators::UpgradeGenerator.new([], { table_prefix: "turnkit_upgrade_test" }, destination_root: directory)
        generator.invoke_all
        assert File.file?(File.join(directory, "app/models/turnkit/delivery.rb"))
        assert File.file?(File.join(directory, "app/models/turnkit/wait.rb"))
        migration = Dir[File.join(directory, "db/migrate/*_add_turnkit_durable_orchestration.rb")].fetch(0)
        Object.class_eval(File.read(migration))
        AddTurnkitDurableOrchestration.migrate(:up)
        assert_equal "pending", connection.select_value("SELECT status FROM turnkit_upgrade_test_turns WHERE uid = 'existing'")
        assert_includes connection.columns(:turnkit_upgrade_test_turns).map(&:name), "claim_token"
        assert connection.indexes(:turnkit_upgrade_test_deliveries).any? { |index| index.unique && index.columns == ["key"] }
        AddTurnkitDurableOrchestration.migrate(:down)
        assert_equal "pending", connection.select_value("SELECT status FROM turnkit_upgrade_test_turns WHERE uid = 'existing'")
        refute connection.table_exists?(:turnkit_upgrade_test_deliveries)
      end
    ensure
      %w[waits deliveries turns].each { |suffix| connection&.drop_table("turnkit_upgrade_test_#{suffix}", if_exists: true) }
    end

    private

      def unique_id(prefix) = "#{prefix}-#{SecureRandom.hex(8)}"

      def create_conversation
        @store.create_conversation("agent_name" => @agent.name, "model" => "test-model")
      end

      def create_turn(conversation, submitted: false)
        @store.create_turn("conversation_id" => conversation.fetch("id"), "agent_name" => @agent.name,
          "status" => "pending", "submitted_at" => (Time.now.utc if submitted))
      end

      def concurrently(count)
        ready = Queue.new
        release = Queue.new
        threads = count.times.map do |index|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ready << true
              release.pop
              yield(index)
            end
          end
        end
        count.times { ready.pop }
        count.times { release << true }
        threads.map(&:value)
      end
  end
else
  class BackgroundDatabaseTest < Minitest::Test
    def test_postgresql_concurrency_suite_requires_dedicated_database
      skip "TURNKIT_TEST_DATABASE_URL is absent; PostgreSQL concurrency tests require the provided dedicated test database"
    end
  end
end
