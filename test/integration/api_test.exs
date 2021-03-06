defmodule ExRabbitPool.Integration.ApiTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias ExRabbitPool.RabbitMQ
  alias ExRabbitPool.Worker.{RabbitConnection, SetupQueue}

  @moduletag :integration

  setup do
    n = :rand.uniform(100)
    pool_id = String.to_atom("test_pool#{n}")

    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("EX_RABBIT_POOL_PORT") || "5672")
    ]

    rabbitmq_conn_pool = [
      name: {:local, pool_id},
      worker_module: RabbitConnection,
      size: 1,
      max_overflow: 0
    ]

    start_supervised!(%{
      id: ExRabbitPool.PoolSupervisorTest,
      start:
        {ExRabbitPool.PoolSupervisor, :start_link,
         [
           [rabbitmq_config: rabbitmq_config, connection_pools: [rabbitmq_conn_pool]],
           ExRabbitPool.PoolSupervisorTest
         ]},
      type: :supervisor
    })

    start_supervised!(
      {SetupQueue,
       {pool_id,
        [
          queues: [
            [
              queue_name: "",
              exchange: "",
              queue_options: [auto_delete: true, exclusive: true],
              exchange_options: [auto_delete: true, exclusive: true]
            ]
          ]
        ]}}
    )

    {:ok, pool_id: pool_id}
  end

  test "executes command with a channel", %{pool_id: pool_id} do
    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = RabbitMQ.publish(channel, "", "", "hello")
    end)
  end

  test "returns :out_of_channels when there aren't more channels", %{pool_id: pool_id} do
    ExRabbitPool.with_channel(pool_id, fn {:ok, _channel} ->
      ExRabbitPool.with_channel(pool_id, fn {:error, error} ->
        assert error == :out_of_channels
      end)
    end)
  end

  test "returns channel to pool after client actions", %{pool_id: pool_id} do
    conn_worker = :poolboy.checkout(pool_id)
    :ok = :poolboy.checkin(pool_id, conn_worker)
    %{channels: [channel1]} = RabbitConnection.state(conn_worker)

    ExRabbitPool.with_channel(pool_id, fn {:ok, _channel} ->
      assert %{channels: []} = RabbitConnection.state(conn_worker)
    end)

    assert %{channels: [channel2]} = RabbitConnection.state(conn_worker)
    refute channel1 == channel2
  end

  test "gets connection to open channel manually", %{pool_id: pool_id} do
    assert {:ok, conn} = ExRabbitPool.get_connection(pool_id)
    assert {:ok, channel} = RabbitMQ.open_channel(conn)
    assert :ok = AMQP.Channel.close(channel)
  end

  test "returns channel to the pool only once when there is a crash in a client using with_channel",
       %{pool_id: pool_id} do
    # TODO: capture [error] Process #PID<X.X.X> raised an exception
    capture_log(fn ->
      conn_worker = :poolboy.checkout(pool_id)
      :ok = :poolboy.checkin(pool_id, conn_worker)
      :erlang.trace(conn_worker, true, [:receive])

      {:ok, client_pid} =
        Task.start(fn ->
          ExRabbitPool.with_channel(pool_id, fn {:ok, _channel} ->
            raise "die"
          end)
        end)

      ref = Process.monitor(client_pid)
      # wait for client to die
      assert_receive {:DOWN, ^ref, :process, ^client_pid, {%{message: "die"}, _stacktrace}}, 1000
      # wait for channel to be put it back into the pool
      assert_receive {:trace, ^conn_worker, :receive,
                      {:"$gen_cast", {:checkin_channel, _channel}}},
                     1000

      # wait for the connection worker to receive a :DOWN message from the client
      # FLAKY assertion: sometimes the message was already received so this function fails
      # assert_receive {:trace, ^conn_worker, :receive,
      #                 {:DOWN, _ref, :process, ^client_pid, {%{message: "die"}, _stacktrace}}}, 1000

      assert %{channels: channels} = RabbitConnection.state(conn_worker)
      assert length(channels) == 1
    end)
  end

  test "returns channel to the pool only once when the channel closes using with_channel",
       %{pool_id: pool_id} do
    conn_worker = :poolboy.checkout(pool_id)
    :ok = :poolboy.checkin(pool_id, conn_worker)
    :erlang.trace(conn_worker, true, [:receive])

    logs =
      capture_log(fn ->
        client_pid =
          spawn(fn ->
            ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
              :ok = AMQP.Channel.close(channel)
              :timer.sleep(500)
            end)
          end)

        ref = Process.monitor(client_pid)
        assert_receive {:DOWN, ^ref, :process, ^client_pid, :normal}, 1000

        assert_receive {:trace, ^conn_worker, :receive,
                        {:"$gen_cast", {:checkin_channel, _channel}}}

        assert_receive {:trace, ^conn_worker, :receive, {:EXIT, _channel_pid, :normal}}
        assert %{channels: channels} = RabbitConnection.state(conn_worker)
        assert length(channels) == 1
      end)

    assert logs =~ "[Rabbit] channel lost reason: :normal"
  end

  test "creates queue with exchange and bindings", %{pool_id: pool_id} do
    assert :ok =
             ExRabbitPool.create_queue_with_bind(
               RabbitMQ,
               pool_id,
               "test_queue",
               "test_exchange",
               queue_options: [auto_delete: true],
               exchange_options: [auto_delete: true]
             )

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "test_exchange", "", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, "test_queue")
      assert {:ok, _} = AMQP.Queue.delete(channel, "test_queue")
    end)
  end

  test "should not fail when binding and declaring default exchange", %{pool_id: pool_id} do
    assert :ok =
             ExRabbitPool.create_queue_with_bind(
               RabbitMQ,
               pool_id,
               "test2_queue",
               "",
               queue_options: [auto_delete: true],
               exchange_options: [auto_delete: true]
             )

    ExRabbitPool.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "", "test2_queue", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, "test2_queue")
      assert {:ok, _} = AMQP.Queue.delete(channel, "test2_queue")
    end)
  end
end
