defmodule KeyfleetWeb.UpkeepAdminControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Accounts, Actors, Treasury}

  @admin "did:privy:upkeep-admin"
  @admin_wallet "0x" <> String.duplicate("a", 40)
  @stranger_wallet "0x" <> String.duplicate("b", 40)

  setup do
    admins = Application.fetch_env!(:regent_credits, :admins)
    Application.put_env(:regent_credits, :admins, [@admin])
    on_exit(fn -> Application.put_env(:regent_credits, :admins, admins) end)
  end

  test "a Credits admin resumes and pauses the upkeep; anyone else gets the not-found page",
       %{conn: conn} do
    {stranger, _account} = signed_in(conn, "did:privy:upkeep-stranger", @stranger_wallet)
    assert stranger |> get("/admin/upkeep") |> html_response(404)
    assert conn |> get("/admin/upkeep") |> html_response(404)
    assert stranger |> post("/admin/upkeep", %{"upkeep" => "resume"}) |> html_response(404)

    assert Treasury.upkeep_paused?()

    {admin, account} = signed_in(conn, @admin, @admin_wallet)
    page = admin |> get("/admin/upkeep") |> html_response(200)
    assert page =~ "Routine upkeep: Paused"
    assert page =~ "Not set up"
    assert page =~ ~s(name="upkeep" value="resume")

    assert admin |> post("/admin/upkeep", %{"upkeep" => "resume"}) |> redirected_to() ==
             "/admin/upkeep"

    refute Treasury.upkeep_paused?()
    assert Treasury.upkeep_switch!().changed_by == account.id
    assert admin |> get("/admin/upkeep") |> html_response(200) =~ "Routine upkeep: Running"

    # The same press again changes nothing: the form says which way it turns.
    post(admin, "/admin/upkeep", %{"upkeep" => "resume"})
    refute Treasury.upkeep_paused?()

    post(admin, "/admin/upkeep", %{"upkeep" => "pause"})
    assert Treasury.upkeep_paused?()
  end

  defp signed_in(conn, privy_id, wallet) do
    account = Accounts.register_verified!(privy_id, wallet, [wallet], actor: %Actors.System{})
    {init_test_session(conn, %{human_account_id: account.id}), account}
  end
end
