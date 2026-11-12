defmodule KeyfleetWeb.LeftMessagesPagesTest do
  # The pages around a message left for the site's team:
  # - /agents carries the Agent Message window for its topic, with a
  #   paste-ready text for each way an agent connects, and the form only for a
  #   signed-in person (test/browser/agent_message.spec.ts leaves one through it);
  # - /admin/messages shows the team every message, newest first, and is the
  #   not-found page for anyone who is not one of the site's admins;
  # - a live page places the same window with its own account, session lease
  #   and client key (`LivePage` here, as no Keyfleet page carries one yet),
  #   and its form leaves a message as the account signed in.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Accounts, LeftMessages}
  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors.{Human, System}
  alias KeyfleetWeb.Components.AgentMessage

  @dialog "agents-message"

  # A live page with the window, as a live page places it.
  defmodule LivePage do
    use KeyfleetWeb, :live_view

    alias Keyfleet.AccessContext
    alias KeyfleetWeb.Components.AgentMessage

    on_mount {KeyfleetWeb.Live.Session, :load_human}

    def mount(_params, _session, socket), do: {:ok, assign(socket, client_key: "live-page")}

    def render(assigns) do
      ~H"""
      <AgentMessage.button id="page-message-button" dialog="page-message" />
      <AgentMessage.dialog
        id="page-message"
        topic="page"
        account={account(@access_context)}
        lease={@session_lease}
        client_key={@client_key}
      />
      """
    end

    defp account(%AccessContext{principal: {:human, account}}), do: account
    defp account(_signed_out), do: nil
  end

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

  test "a live page's window leaves a message as the account signed in, and has no form signed out" do
    {:ok, signed_out, _html} = live_isolated(build_conn(), LivePage)
    refute has_element?(signed_out, "#page-message-person-form")
    assert has_element?(signed_out, "#page-message .agent-message__text", "messages leave page")

    {conn, account} = signed_in()
    session = get_session(conn)

    # Drawn for this sign-in, as the router's live session would draw it.
    rendered = %{
      "render_topic" => SessionAuthority.topic(session["session_lineage"]),
      "render_route" => "/"
    }

    {:ok, view, _html} =
      conn |> connects_with(session) |> live_isolated(LivePage, session: rendered)

    form = "#page-message-person-form"
    assert has_element?(view, form)

    view
    |> form(form, message: %{body: "From a live page", reply_to: "me@example.com"})
    |> render_submit()

    assert has_element?(view, "#page-message-person-receipt")

    put_admins([account.privy_user_id])
    admin = %RegentAgents.Person{privy_user_id: account.privy_user_id, role: :admin}
    assert %{results: [left | _]} = LeftMessages.list_left_messages!(actor: admin)

    assert {left.topic, left.body, left.reply_to, left.human_account_id} ==
             {"page", "From a live page", "me@example.com", account.id}
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
