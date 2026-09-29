defmodule Keyfleet.AgentsListenerTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox

  @owner "did:privy:keyfleet-listener-owner"

  test "an agent change any site announces reaches the person's pages here" do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, RegentAgents.topic(@owner))

    # Announced outside the test's transaction, as another site's commit is.
    Sandbox.unboxed_run(Keyfleet.Repo, fn ->
      Keyfleet.Repo.query!("SELECT pg_notify($1, $2)", [RegentAgents.channel(), @owner])
    end)

    assert_receive :agents_changed, 2_000
  end
end
