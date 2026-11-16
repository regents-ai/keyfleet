defmodule Keyfleet.Accounts.EnsIdentityTest do
  # An account's ENS lookup is pending, done or failed, and moves only as its
  # record declares: asking makes it pending from any stage, and only a
  # pending lookup is done or failed. Ethereum is a local server answering
  # as a node does for a wallet with no name.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  alias AshStateMachine.Errors.NoMatchingTransition
  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.EnsIdentity
  alias Keyfleet.Accounts.EnsIdentity.Workers.LookUp
  alias Keyfleet.Actors.System
  alias KeyfleetWeb.SignedAgentHelpers

  @wallet "0x6767676767676767676767676767676767676767"
  # The context the lookup job runs its actions with.
  @job [context: %{private: %{ash_oban?: true}}]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)

    {:ok, account} =
      Accounts.register_verified("did:privy:ens-stages", @wallet, [@wallet], actor: %System{})

    rpc = Application.get_env(:keyfleet, :ethereum_read_rpc_url)
    on_exit(fn -> Application.put_env(:keyfleet, :ethereum_read_rpc_url, rpc) end)
    %{account: account}
  end

  test "a pending lookup the job finishes is done, and one whose last try fails is failed", %{
    account: account
  } do
    ethereum!(200)
    lookup = ask(account)
    assert {:ok, _done} = perform_job(LookUp, args(lookup))
    assert %{lookup_state: :done, ens_name: nil} = stored(lookup)

    ethereum!(503)
    ask(account)

    assert_raise Ash.Error.Unknown, fn ->
      perform_job(LookUp, args(lookup), attempt: 2, max_attempts: 3)
    end

    assert %{lookup_state: :pending} = stored(lookup)
    perform_job(LookUp, args(lookup), attempt: 3, max_attempts: 3)
    assert %{lookup_state: :failed} = stored(lookup)
  end

  test "only a pending lookup is done or failed, and asking makes any lookup pending again", %{
    account: account
  } do
    lookup = ask(account)

    for stage <- ["done", "failed"] do
      Keyfleet.Repo.query!(
        "UPDATE keyfleet_app.account_ens_identities SET lookup_state = $1 WHERE id = $2",
        [stage, Ecto.UUID.dump!(lookup.id)]
      )

      finished = stored(lookup)

      for move <- [:look_up, :lookup_failed] do
        assert {:error, %Ash.Error.Invalid{errors: [%NoMatchingTransition{}]}} =
                 finished |> Ash.Changeset.for_update(move, %{}, @job) |> Ash.update()
      end

      assert stored(lookup) == finished
      assert %{lookup_state: :pending} = ask(account)
    end
  end

  test "the database holds a lookup in no other stage", %{account: account} do
    lookup = ask(account)

    assert_raise Postgrex.Error, ~r/account_ens_identities_lookup_state/, fn ->
      Keyfleet.Repo.query!(
        "UPDATE keyfleet_app.account_ens_identities SET lookup_state = 'stuck' WHERE id = $1",
        [Ecto.UUID.dump!(lookup.id)]
      )
    end
  end

  defp ask(account),
    do: Accounts.request_ens_lookup!(account.id, @wallet, actor: %System{})

  defp stored(lookup), do: Ash.get!(EnsIdentity, lookup.id)

  defp args(lookup), do: %{"primary_key" => %{"id" => lookup.id}}

  # Every call is answered with an empty word, as Ethereum answers the ENS
  # registry for a wallet with no reverse record, or with `status` alone.
  defp ethereum!(status) do
    url =
      SignedAgentHelpers.serve!({:ethereum, status}, fn conn, _opts ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          status,
          JSON.encode!(%{jsonrpc: "2.0", id: 1, result: "0x" <> String.duplicate("0", 64)})
        )
      end)

    Application.put_env(:keyfleet, :ethereum_read_rpc_url, url)
  end
end
