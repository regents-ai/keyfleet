defmodule KeyfleetWeb.ReadTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KeyfleetWeb.Components.VerifiedConnections
  alias KeyfleetWeb.Read

  @identity %{provider: :x, username: "account_user", display_name: "Account User"}

  defp socket(read), do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, balance: read}}

  defp settled(read, result),
    do: socket(read) |> Read.settle({Read, :balance, read.generation}, result) |> balance()

  defp balance(socket), do: socket.assigns.balance

  test "an answer lands as ready, or as empty when there is nothing to show" do
    loading = %Read{state: :loading, owner: "wallet", generation: 1}

    assert %Read{state: :ready, value: 42, read_at: %DateTime{}} =
             settled(loading, {:ok, {:ok, 42}})

    assert %Read{state: :empty, value: []} = settled(loading, {:ok, {:ok, []}})
  end

  test "a failure is an error with no earlier answer, and stale with one" do
    first = %Read{state: :loading, owner: "wallet", generation: 1}
    assert %Read{state: :error, value: nil, error: :timeout} = settled(first, {:exit, :timeout})

    again = %{first | value: 42, read_at: DateTime.utc_now()}

    assert %Read{state: :stale, value: 42, error: :down} =
             settled(again, {:ok, {:error, :down}})
  end

  test "an answer for an earlier generation is dropped" do
    read = %Read{state: :loading, owner: "wallet", generation: 2}

    assert socket(read) |> Read.settle({Read, :balance, 1}, {:ok, {:ok, 42}}) |> balance() == read
  end

  test "clearing empties the read and moves it past any running answer" do
    read = %Read{state: :ready, owner: "wallet", value: 42, generation: 3}

    assert socket(read) |> Read.clear(:balance) |> balance() == %Read{generation: 4}
  end

  describe "the connections panel" do
    defp panel(identities, read_state) do
      render_component(&VerifiedConnections.verified_connections/1,
        id: "connections",
        identities: identities,
        read_state: read_state
      )
    end

    test "waits for the first read without showing an empty list" do
      html = panel(nil, :loading)

      assert html =~ "Loading your connections…"
      refute html =~ "Not connected"
    end

    test "says a failed first read failed rather than showing no connections" do
      html = panel(nil, :error)

      assert html =~ "Your connections couldn’t be loaded."
      refute html =~ "Not connected"
    end

    test "keeps the last list after a failed refresh and says it is old" do
      html = panel([@identity], :stale)

      assert html =~ "This is what they were last time."
      assert html =~ "@account_user"
    end
  end
end
