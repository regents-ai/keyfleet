defmodule KeyfleetWeb.LeftMessagesPagesTest do
  # The pages around a message left for the site's team:
  # - /agents carries the Agent Message window for its topic, with a
  #   paste-ready text for each way an agent connects, and the form only for a
  #   signed-in person (test/browser/agent_message.spec.ts leaves one through it),
  #   and the form leaves a message as the account signed in;
  # - /admin/messages shows the team every message, newest first, and is the
  #   not-found page for anyone who is not one of the site's admins.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Accounts, LeftMessages}
  alias Keyfleet.Actors.{Human, System}
  alias KeyfleetWeb.Components.AgentMessage

  @dialog "agents-message"

  test "/agents offers the Agent Message texts to everyone, and the form only to a signed-in person" do
    signed_out = page(build_conn(), "/agents")

    texts =
      signed_out
      |> LazyHTML.query("##{@dialog} .agent-message__text pre code")
      |> Enum.map(&LazyHTML.text/1)

    assert texts == Enum.map(AgentMessage.texts("agents"), & &1.text)
    assert [cli, mcp, webmcp] = texts
    assert cli =~ "regents keyfleet messages leave agents"
    assert mcp =~ "messages_leave" and webmcp =~ "messages_leave"

    targets =
      signed_out
      |> LazyHTML.query("##{@dialog} [data-copy-target]")
      |> LazyHTML.attribute("data-copy-target")

    assert length(targets) == 3

    for target <- targets,
        do: assert(Enum.count(LazyHTML.query(signed_out, "#" <> target)) == 1)

    form = "##{@dialog}-person-form"
    assert Enum.empty?(LazyHTML.query(signed_out, form))

    {conn, _account} = signed_in()
    assert Enum.count(LazyHTML.query(page(conn, "/agents"), form)) == 1
  end

  test "/admin/messages shows the team every message, and is not found for anyone else" do
    {person, account} = signed_in()
    {:ok, older} = leave(account, "agents", "First")
    {:ok, newer} = leave(account, "watchdog", "Second")

    assert build_conn() |> get("/admin/messages") |> response(404)
    assert person |> get("/admin/messages") |> response(404)

    put_admins([account.privy_user_id])
    page = page(person, "/admin/messages")

    ids = page |> LazyHTML.query("#admin-messages > li") |> LazyHTML.attribute("id")
    assert Enum.take(ids, 2) == ["message-#{newer.id}", "message-#{older.id}"]
    assert LazyHTML.text(page) =~ "Second"
  end

  test "the Agents page's form leaves a message as the account signed in, and is not there signed out" do
    form = "##{@dialog}-person-form"

    {:ok, signed_out, _html} = live(build_conn(), "/agents")
    refute has_element?(signed_out, form)
    assert has_element?(signed_out, "##{@dialog} .agent-message__text", "messages leave agents")

    {conn, account} = signed_in()
    {:ok, view, _html} = live(conn, "/agents")
    assert has_element?(view, form)

    view
    |> form(form, message: %{body: "From the Agents page", reply_to: "me@example.com"})
    |> render_submit()

    assert has_element?(view, "##{@dialog}-person-receipt")

    put_admins([account.privy_user_id])
    admin = %RegentAgents.Person{privy_user_id: account.privy_user_id, role: :admin}
    assert %{results: [left | _]} = LeftMessages.list_left_messages!(actor: admin)

    assert {left.topic, left.body, left.reply_to, left.human_account_id} ==
             {"agents", "From the Agents page", "me@example.com", account.id}
  end

  defp leave(account, topic, body),
    do:
      LeftMessages.leave_message(%{topic: topic, body: body},
        actor: Human.for_account(account),
        context: %{client_key: Ecto.UUID.generate()}
      )

  defp page(conn, path),
    do:
      conn
      |> put_req_header("accept", "text/html")
      |> get(path)
      |> html_response(200)
      |> LazyHTML.from_document()

  defp signed_in do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    account =
      Accounts.register_verified!("did:privy:messages-page-" <> wallet, wallet, [wallet],
        actor: %System{}
      )

    {init_test_session(build_conn(), %{human_account_id: account.id}), account}
  end

  defp put_admins(admins) do
    for app <- [:keyfleet, :regent_agents] do
      old = Application.fetch_env(app, :admins)
      Application.put_env(app, :admins, admins)

      on_exit(fn -> restore_admins(app, old) end)
    end
  end

  defp restore_admins(app, {:ok, admins}), do: Application.put_env(app, :admins, admins)
  defp restore_admins(app, :error), do: Application.delete_env(app, :admins)
end
