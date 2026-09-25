defmodule Keyfleet.Keeper.BootTest do
  # Changes the app's keeper configuration and log level, and starts the one
  # named keeper process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Keyfleet.KeeperHelpers, only: [answering: 1, deploy!: 3, sent: 0, view!: 1, view!: 2]

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, Fleets, Keeper, Release, Repo}
  alias Keyfleet.Keeper.{Runner, StubNode}
  alias Keyfleet.Keeper.Supervisor, as: KeeperSupervisor

  # Anvil's first public test account. Never a real key.
  @anvil_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @keeper "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @other_keeper "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @fleet "0x5fbdb2315678afecb367f032d93f642f64180aa3"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Fleets.bootstrap_catalog!()

    config = Application.fetch_env!(:keyfleet, Keyfleet.Keeper)
    level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Application.put_env(:keyfleet, Keyfleet.Keeper, config)
      Logger.configure(level: level)
    end)

    %{config: config}
  end

  describe "without a key" do
    test "no keeper starts, and the log says so once" do
      log = capture_log(fn -> assert Keyfleet.Application.keeper_child() == nil end)

      assert [_line] =
               Regex.scan(
                 ~r/Keeper off: no KEYFLEET_KEEPER_PRIVATE_KEY in production; nothing on this site sends transactions\./,
                 log
               )
    end

    test "the status command says the keeper is off" do
      assert capture_io(fn -> Release.keeper_status!() end) ==
               "Keeper off: KEYFLEET_KEEPER_PRIVATE_KEY is not set.\n"
    end
  end

  describe "with a key" do
    setup %{config: config} do
      Application.put_env(
        :keyfleet,
        Keyfleet.Keeper,
        Keyword.put(config, :private_key, @anvil_key)
      )

      StubNode.put_chain()
      :ok
    end

    test "a key starts the keeper under its own supervisor, which the site does not restart" do
      assert %{id: KeeperSupervisor, start: {KeeperSupervisor, :start_link, [[]]}} =
               spec = Keyfleet.Application.keeper_child()

      assert spec.restart == :temporary
    end

    test "the keeper is started again when it crashes, until its supervisor gives up" do
      {supervisor, log} =
        with_log(fn ->
          supervisor = start_supervised!(Keyfleet.Application.keeper_child())
          down = Process.monitor(supervisor)

          # Three restarts within a minute are allowed; the fourth crash is one too many.
          Enum.reduce(1..4, nil, fn _crash, old ->
            runner = next_runner(old)
            :sys.get_state(runner)
            # A message it has no clause for crashes it.
            send(runner, :unexpected)
            runner
          end)

          assert_receive {:DOWN, ^down, :process, ^supervisor, :shutdown}, 5_000
          supervisor
        end)

      refute Process.alive?(supervisor)
      assert Process.whereis(Runner) == nil
      assert Process.alive?(Process.whereis(Keyfleet.Supervisor))

      # Each crash is logged as an error, and never shows the key.
      assert [_, _, _, _] = Regex.scan(~r/Keeper on:/, log)

      assert [_, _, _, _] =
               Regex.scan(~r/\[error\] GenServer Keyfleet.Keeper.Runner terminating/, log)

      assert log =~ @keeper
      refute log =~ key_digits()
      refute log =~ String.upcase(key_digits())
    end

    test "a database that cannot answer at start is tried again, not a crash" do
      # No database connection is open to the keeper's process.
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      {runner, log} =
        with_log(fn ->
          runner = start_supervised!(Runner)
          :sys.get_state(runner)
          runner
        end)

      assert log =~ "Keeper could not start, trying again in 30 s"
      refute log =~ "Keeper on"
      assert Process.alive?(runner)

      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)

      log =
        capture_log(fn ->
          send(runner, :start)
          :sys.get_state(runner)
        end)

      assert log =~ "Keeper on: sending from #{@keeper} on chain 8453."
    end

    test "a stopped keeper says so as it starts, and not that it is on" do
      {:ok, _stop} = Keeper.record_stop(:reveal, :foreign_nonce, "someone else sent.")

      log =
        capture_log(fn ->
          runner = start_supervised!(Runner)
          :sys.get_state(runner)
        end)

      assert log =~
               "Keeper stopped (foreign_nonce): it sends nothing from #{@keeper} until bin/keeper-resume is run and the site restarted."

      refute log =~ "Keeper on"
      refute log =~ "left a transaction waiting"
    end

    test "the keeper says where it sends from, and its status never shows the key" do
      {status, log} =
        with_log(fn ->
          pid = start_supervised!(Runner)
          :sys.get_status(pid)
        end)

      assert log =~ "Keeper on: sending from #{@keeper} on chain 8453."
      refute log =~ key_digits()

      shown = inspect(status, limit: :infinity, printable_limit: :infinity)
      assert shown =~ @keeper
      refute shown =~ key_digits()
      refute shown =~ String.upcase(key_digits())

      {:ok, key} = Base.decode16(key_digits(), case: :lower)
      assert :binary.match(:erlang.term_to_binary(status), key) == :nomatch
    end

    test "the keeper's reveal round asks for a sold key, and its next rounds do not ask again" do
      deploy!("fibonacci_syndicate", @fleet, 8_453)
      ChainHelpers.seed_cursor!("fibonacci_syndicate")
      coordinator = "0x" <> String.duplicate("c0", 20)

      StubNode.put_chain(
        calls:
          answering(%{
            {@fleet, view!(:vrf_coordinator)} => [coordinator],
            {@fleet, view!(:vrf_subscription_id)} => [5],
            {coordinator, view!(:get_subscription, [5])} => [
              0,
              20_000_000_000_000_000,
              0,
              @other_keeper,
              160,
              1,
              @fleet
            ],
            {@fleet, view!(:total_minted)} => [1],
            {@fleet, view!(:reveal_seed, [1])} => [0],
            {@fleet, view!(:reveal_requested_at, [1])} => [0],
            {@fleet, view!(:launch_state)} => [0],
            {@fleet, view!(:protocol_share_owed)} => [0]
          })
      )

      capture_log(fn ->
        runner = start_supervised!(Runner)

        send(runner, :reveal)
        :sys.get_state(runner)
        assert [%{to: @fleet}] = sent()

        # The key was just asked for, so neither round sends anything more.
        send(runner, :reveal)
        send(runner, :income)
        :sys.get_state(runner)
        assert [_request] = sent()
      end)

      assert [%{job: :reveal, outcome: :sent, sent: 1}] = Ash.read!(Keeper.Run, actor: %System{})
    end

    test "the status command shows the wallet, its spending, its rounds and transactions" do
      Keeper.record_run!(
        %{
          job: :reveal,
          started_at: ~U[2026-09-23 10:00:00.000000Z],
          finished_at: ~U[2026-09-23 10:00:01.000000Z],
          outcome: :paused_gas,
          sent: 0,
          skipped: 3
        },
        actor: %System{}
      )

      deploy!("fibonacci_syndicate", @fleet, 8_453)
      tx = sent!()

      other_wallet =
        sent!(%{from_address: @other_keeper, tx_hash: "0x" <> String.duplicate("cd", 32)})

      other_chain = sent!(%{chain_id: 1, tx_hash: "0x" <> String.duplicate("ef", 32)})

      {:ok, _stop} =
        Keeper.record_stop(:income, :tx_hash_mismatch, "the node named another hash.")

      {:ok, _tx} =
        Keeper.settle(tx, %{
          status: :mined,
          block_number: 5,
          gas_used: 100_000,
          effective_gas_price: 10_000_000,
          l1_fee_wei: 1_000,
          cost_wei: 1_000_000_001_000,
          result: "reveal_refused"
        })

      output = capture_io(fn -> Release.keeper_status!() end)

      assert output =~ "Keeper wallet #{@keeper}\n"
      assert output =~ "Chain 8453, balance 0.05 ETH\n"

      assert output =~
               "Spent in the last 24 hours: 0.000001000000001 ETH, and up to 0 ETH more waiting (limit 0.01 ETH)\n"

      assert output =~ "reveal: paused_gas at 2026-09-23 10:00:01.000000Z, 0 sent, 3 skipped\n"
      assert output =~ ~r/income: stopped at \S+ \S+, 0 sent, 0 skipped\n/

      assert output =~
               ~r/Last 20 transactions:\n\S+ \S+ reveal fibonacci_syndicate request_reveal #{@fleet} nonce 0 mined reveal_refused #{tx.tx_hash}\n/

      refute output =~ other_wallet.tx_hash
      refute output =~ other_chain.tx_hash

      assert output =~
               ~r/Stopped \(tx_hash_mismatch\) at \S+ \S+: the node named another hash\.\n/

      assert output =~ "run bin/keeper-resume and restart the site."

      refute output =~ key_digits()
    end

    test "the resume command clears a stop, and says the site must restart" do
      assert capture_io(fn -> Release.keeper_resume!() end) == "The keeper is not stopped.\n"

      {:ok, stop} = Keeper.record_stop(:reveal, :foreign_nonce, "someone else sent.")

      assert capture_io(fn -> Release.keeper_resume!() end) ==
               "Cleared the keeper's stop (foreign_nonce) from #{stop.finished_at}. " <>
                 "Restart the site for the keeper to send again.\n"

      assert {:ok, nil} = Keeper.stopped()
      assert capture_io(fn -> Release.keeper_status!() end) =~ "Not stopped\n"
      assert capture_io(fn -> Release.keeper_resume!() end) == "The keeper is not stopped.\n"
    end
  end

  test "the status and resume launchers run their guarded commands without arguments" do
    for {launcher, command} <- [
          {"keeper-status", :keeper_status},
          {"keeper-resume", :keeper_resume}
        ] do
      path = "rel/overlays/bin/#{launcher}"
      script = File.read!(path)

      assert script =~ "Keyfleet.Release.#{command}()"
      assert script =~ "KEYFLEET_RELEASE_COMMAND=migrate"
      refute script =~ "KEYFLEET_KEEPER_PRIVATE_KEY"
      refute script =~ "echo"
      assert File.stat!(path).mode |> Bitwise.band(0o100) != 0
      assert {command, 0} in Release.__info__(:functions)
    end
  end

  defp key_digits, do: String.slice(@anvil_key, 2..-1//1)

  # The Runner the keeper's supervisor has running, once it is not `old`.
  defp next_runner(old) do
    case Process.whereis(Runner) do
      runner when is_pid(runner) and runner != old ->
        runner

      _none_or_old ->
        Process.sleep(5)
        next_runner(old)
    end
  end

  defp sent!(attrs \\ %{}) do
    Keeper.record_sent_tx!(
      Map.merge(
        %{
          job: :reveal,
          fleet_id: "fibonacci_syndicate",
          function: :request_reveal,
          target: @fleet,
          from_address: @keeper,
          args: %{"arg" => 1},
          chain_id: 8_453,
          nonce: 0,
          tx_hash: "0x" <> String.duplicate("ab", 32),
          max_fee: 11_000_000,
          max_priority_fee: 1_000_000,
          gas_limit: 200_000
        },
        attrs
      ),
      actor: %System{}
    )
  end
end
