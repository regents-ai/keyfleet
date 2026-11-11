defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys, ProposalHelpers, SharedReading}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.Components.SendAgent
  alias KeyfleetWeb.{FleetNow, KeyLinks}
  alias Phoenix.Socket.Broadcast

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - every way to buy is called "Buy Key", the Key's number and price beside
  #   it and never in its label
  # - while Classic is coming soon, the card's tag names Key 1 and its price,
  #   but "Buy Key" says it can't be pressed, with "Sales open soon" under it,
  #   links nowhere, and the header offers no "Buy Key"
  # - once Classic is on sale, the hero's "Buy Key" and the header's open the
  #   "Buy Key" window, which holds the fleet's own Approve and Buy, and the
  #   line under the button and the card's tag name the Key on offer and its
  #   price after the Keys sold
  # - once every Classic Key is sold, the button can't be pressed and says so
  # - top to bottom the page holds Classic's hero, Classic Keyfleet, what a
  #   fleet can use and the starting ideas, and the Markdown homepage the same
  # - a Classic read that fails is said to have failed and never shown as zero
  # - a burst of notices is answered by one read of each fleet it names, for
  #   every open homepage at once, and a post taken off a wall reads its fleet
  #   again
  # - Classic's sea draws the ships of the one reading every open page shares,
  #   from the first render; the page reads no ships of its own, a new reading
  #   reaches the open page, and pressing a ship opens its Key
  # - the command box shows the homepage instruction whole and copies exactly
  #   what it shows
  # - the page leads with the headline and what a fleet gives an agent; the
  #   Markdown homepage carries them with the tagline as Sean wrote it, says
  #   Classic opens soon until it does, then links its page
  # - "Watch a live fleet" and "Connect my agent" both open Classic #1's own
  #   page, where Buy Key and the setup list bring an agent in; Classic #1's
  #   figures each keep their own name: Keys sold out of all, the agents here,
  #   the next Key's price and the goal it is working on, which links its
  #   workspace
  # - launch-gate: internal links stay on the fleets' maps and workspaces, the
  #   account page, the public documents, or anchors that exist
  # - the page ends with the starting ideas for a shared goal as Sean wrote
  #   them, each link to another site opening in a new tab, and the Markdown
  #   homepage carries the same section
  # - signed in, the header's name opens the account menu, with Sign out,
  #   Manage Account, the account's agents and Pair New Agent opening the
  #   pairing window, and an agent paired while the page is open shows in it;
  #   Fleets beside the name opens Classic; signed out there is neither

  @classic "fleet_tech_classic"
  @club "regents_club"
  @owner "0x" <> String.duplicate("a", 40)

  setup context do
    Fleets.bootstrap_catalog!()

    unless context[:classic_undeployed] do
      ChainHelpers.deploy!(@classic)
      ChainHelpers.seed_cursor!(@classic)
    end

    Enum.each(Fleets.catalog_ids(), &Workspace.open_log/1)
    read_fleets()
    :ok
  end

  test "SMOKE: the homepage mounts and keeps its landmark", %{conn: conn} do
    assert conn |> get("/") |> html_response(200)
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#public-home")
    refute has_element?(view, "#app-shell")
  end

  test "signed in, the homepage has the account menu and Fleets; signed out, neither",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#account-menu")
    refute has_element?(view, "[popovertarget=account-menu]")
    refute has_element?(view, "#shell-fleets")

    wallet = "0x" <> String.duplicate("b", 40)

    account =
      Keyfleet.Accounts.register_verified("did:privy:home-panel", wallet, [wallet],
        actor: %Actors.System{}
      )
      |> then(fn {:ok, account} -> account end)

    {:ok, view, _html} = conn |> init_test_session(%{human_account_id: account.id}) |> live("/")

    assert has_element?(view, "#shell-header #account-chip[popovertarget=account-menu]")
    assert has_element?(view, "#account-control a#shell-fleets[href='/classic/1']", "Fleets")
    refute has_element?(view, "#account-control [data-account-target=sign-out]")
    assert has_element?(view, "#account-menu[popover] [data-account-target=sign-out]", "Sign out")
    assert has_element?(view, ~s(#account-menu a[href="/account"]), "Manage Account")

    assert has_element?(
             view,
             ~s(#account-menu button[data-pair-open][aria-controls="shell-pairing"]),
             "Pair New Agent"
           )

    assert has_element?(view, "dialog#shell-pairing form#shell-pairing-box")

    assert has_element?(view, ~s(#shell-agents a[href="/account/agents"]), "Manage")
    refute has_element?(view, "#shell-agents li")

    %{code: code} =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: "did:privy:home-panel"}
      )

    RegentAgents.pair_agent!(code, "Astra", :hermes,
      actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate("c", 40)}
    )

    # Announced after the pairing's commit (`RegentAgents.channel/0`), which the
    # test's transaction never makes. The page passes it on to the panel, which
    # draws after the render that follows.
    send(view.pid, :agents_changed)
    render(view)
    assert has_element?(view, "#shell-agents li", "Astra")
  end

  @tag :classic_undeployed
  test "while Classic is coming soon, Buy Key can't be pressed and says why",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(
             view,
             ~s(button#home-buy-key[aria-disabled="true"][aria-describedby="home-buy-why"]),
             "Buy Key"
           )

    assert text(view, "#home-buy-key") == "Buy Key"
    refute has_element?(view, "#home-buy-price")
    assert text(view, "#home-buy-tag") == "Key 1 · 10 USDC"
    assert text(view, "#home-buy-why") == "Sales open soon"
    assert text(view, "#home-classic-price") == "10 USDC"

    assert text(view, "#home-price-tip") =~
             "Keys increase steadily in cost until 100 USDC for the last Key."

    refute has_element?(view, "#shell-get-key")
  end

  test "once Classic is on sale, Buy Key has the Key on offer under it and opens the Buy Key window",
       %{conn: conn} do
    for token_id <- 1..3, do: issue!(@classic, token_id)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")

    price = Keyfleet.Fleets.Presets.progress(@classic, 3).next_price

    assert text(view, ~s(button#home-buy-key[aria-describedby="home-buy-price"])) == "Buy Key"
    assert text(view, "#home-buy-price") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    assert text(view, "#home-buy-tag") == "Key 4 · #{KeyfleetWeb.FleetLive.usdc(price)}"
    refute has_element?(view, "#home-buy-why")
    assert text(view, "#home-classic-price") == KeyfleetWeb.FleetLive.usdc(price)
    assert text(view, "#home-classic-sold") == "3 of 1,024"

    view |> element("button#home-buy-key") |> render_click()

    assert has_element?(
             view,
             ~s(dialog#buy-key button#buy-key-button[data-onchain-step="buy"])
           )

    assert has_element?(
             view,
             ~s(dialog#buy-key button#buy-key-approve[data-onchain-step="approve"])
           )

    refute has_element?(view, "#buy-key-go")
  end

  test "once Classic is on sale, the header's Buy Key opens the Buy Key window", %{
    conn: conn
  } do
    issue!(@classic, 1)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")
    assert text(view, "button#shell-get-key") == "Buy Key"
    view |> element("button#shell-get-key") |> render_click()

    assert has_element?(view, "dialog#buy-key")
  end

  test "once Classic is on sale, Buy Key opens its window: the Key cards turning, how many are sold, the Key on offer, the price, Buy and Close",
       %{conn: conn} do
    issue!(@classic, 1)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")
    view |> element("button#home-classic-buy") |> render_click()

    assert text(view, "#buy-key-title") == "Buy Key"
    assert has_element?(view, "dialog#buy-key #buy-key-cards.key-cards")
    assert text(view, "#buy-key-traits") == "Your Key’s traits are randomized"

    assert ["Sold", "Key", "Price" <> _tip] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("dialog#buy-key dl dt")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert text(view, "#buy-key-sold") == "1 of 1,024"
    assert text(view, "#buy-key-number") == "2"
    assert text(view, "#buy-key-price") == "10.02 USDC"

    assert text(view, "#buy-key-price-tip") =~
             "Your wallet asks twice: Approve lets the sale take this much USDC, then Buy pays it"

    assert has_element?(view, "dialog#buy-key #buy-key-button")
    assert has_element?(view, "dialog#buy-key #buy-key-close", "Close")
  end

  test "once every Classic Key is sold, Buy Key can't be pressed and says so",
       %{conn: conn} do
    issue!(@classic, 1024)
    read_fleets()

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ~s(button#home-buy-key[aria-disabled="true"]))
    assert text(view, "#home-buy-why") == "1,024/1,024 Keys sold"
    assert text(view, "#home-classic-price") == "Sold out"
  end

  test "a Classic that can't be read leaves the homepage drawn, saying so",
       %{conn: conn} do
    Keyfleet.Repo.query!(
      "ALTER TABLE #{Keyfleet.Repo.default_prefix()}.fleets RENAME TO fleets_away"
    )

    capture_log(fn ->
      first_read(@classic)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#public-home")
      assert text(view, "#home-classic-price") == "—"
      assert text(view, "#home-classic-sold") == "—"
      assert text(view, "#home-buy-why") == "Couldn’t read sales just now"
    end)
  end

  test "the command box shows the homepage instruction and copies what it shows",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "#home-instruction-copy", "data-copy-text") ==
             [SendAgent.home_instruction()]

    assert text(view, "#home-instruction") == SendAgent.home_instruction()
    # A copy of the homepage's line counts as a step in.
    assert attribute(html, "#home-instruction-copy", "data-step") == ["copy"]
  end

  test "a burst of notices is answered by one read of each fleet, for every open homepage",
       %{conn: conn} do
    producer = start_supervised!(FleetNow)
    {:ok, _view, _html} = live(conn, "/")
    {:ok, _view, _html} = live(conn, "/")

    # Watch the fleets the producer reads; the two open pages read nothing.
    :erlang.trace_pattern({FleetNow, :read, 1}, true, [:global])
    :erlang.trace(producer, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({FleetNow, :read, 1}, false, [:global]) end)

    send(producer, {:graph_notable, @club})
    send(producer, {:graph_notable, @club})
    send(producer, {:proposals_changed, @club})
    send(producer, {:keys_changed, @classic, [1]})

    assert_receive {:trace, ^producer, :call, {FleetNow, :read, [@club]}}, 2_000
    assert_receive {:trace, ^producer, :call, {FleetNow, :read, [@classic]}}
    refute_receive {:trace, ^producer, :call, {FleetNow, :read, _}}, 1_500
  end

  # R-20261019-wall-removal-reads-again: a post taken off a Club wall stopped
  # every open homepage, which knew no such notice. The fleets' reading hears
  # it and reads the fleet again.
  test "a post taken off a wall reads its fleet again" do
    producer = start_supervised!(FleetNow)

    :erlang.trace_pattern({FleetNow, :read, 1}, true, [:global])
    :erlang.trace(producer, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({FleetNow, :read, 1}, false, [:global]) end)

    send(producer, %Broadcast{
      topic: Keyfleet.Rooms.topic(@club, :public),
      event: "wall_removed",
      payload: %{fleet_id: @club, token_id: 17, message_id: Ecto.UUID.generate()}
    })

    assert_receive {:trace, ^producer, :call, {FleetNow, :read, [@club]}}, 2_000
  end

  # R-20261019-home-ships-shared: each open homepage read the fleets' ships
  # again for every burst of notices, and drew its seas empty until it had.
  describe "Classic's sea" do
    test "draws the ships of the one shared reading from the first render", %{conn: conn} do
      proposal!(1, 7)
      read_fleets()

      static = conn |> get("/") |> html_response(200)
      assert crew(static, "#home-classic-sea") == [7]

      {:ok, _view, html} = live(conn, "/")
      assert crew(html, "#home-classic-sea") == [7]
    end

    test "takes new ships only from the shared reading, and a ship opens its card",
         %{conn: conn} do
      proposal!(1, 7)
      read_fleets()
      {:ok, view, _html} = live(conn, "/")

      # Saved, but not yet in the reading: the page reads no ships of its own.
      proposal!(2, 9)
      assert crew(render(view), "#home-classic-sea") == [7]

      # Both proposals were seen in the same moment, so their order is not told.
      FleetNow.read(@classic)
      assert Enum.sort(crew(render(view), "#home-classic-sea")) == [7, 9]

      render_hook(view, "open_ship", %{"id" => "#{@classic}:9"})

      assert has_element?(
               view,
               "#harbour-agent a[href='#{KeyLinks.page_path(@classic, 9)}']",
               "View"
             )

      render_hook(view, "close_agent", %{})
      refute has_element?(view, "#harbour-agent")
    end
  end

  test "the page and the Markdown homepage lead with the headline, and the Markdown with Sean's tagline",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert text(view, "#home-title") == "A persistent team for your AI agent."

    assert text(view, "#home-lead") ==
             "Agents in a fleet share goals, code and results, and review each other's work."

    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    assert String.starts_with?(markdown, "# Keyfleet\n\nA persistent team for your AI agent.\n")

    assert markdown =~
             " review each other's work. Your personal agent joins a Fleet with a Key.\n"

    assert Regex.scan(~r/^## (.+)$/m, markdown, capture: :all_but_first) == [
             ["Classic Keyfleet"],
             ["Fleet Tools"],
             ["Shared Goals"],
             ["More"]
           ]

    [_, section] = String.split(markdown, "\n## Classic Keyfleet\n", parts: 2)
    [_, path] = Regex.run(~r{\[Live activity\]\(https?://[^/]+(/[^)]+)\)}, section)
    assert path == "/fleets/fleet_tech_classic.md"
    assert build_conn() |> get(path) |> response(200) =~ "Classic #1"
  end

  test "both ways in open Classic #1's page, over Classic #1's figures", %{conn: conn} do
    for token_id <- 1..2, do: issue!(@classic, token_id)
    Workspace.create(@classic, "goal", %{"title" => "Chart the bay", "outcome" => "O"}, by: 1)
    read_fleets()
    Keyfleet.Agents.Here.read(@classic)

    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "a#home-watch", "href") == ["/classic/1"]
    assert text(view, "#home-watch") == "Watch a live fleet"
    assert attribute(html, "a#home-connect", "href") == ["/classic/1"]
    assert text(view, "#home-connect") == "Connect my agent"
    # Each press is counted by the step it names (assets/js/launch_steps.ts).
    assert attribute(html, "a#home-watch", "data-step") == ["watch"]
    assert attribute(html, "a#home-connect", "data-step") == ["connect"]
    assert text(view, "#home-watch-note") == "No wallet needed to watch."

    assert text(view, "#home-hero-fleet") == "Classic #1 now"

    assert ["Keys sold", "Agents here", "Next Key" <> _tip] =
             html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#home-classic-facts dt")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert text(view, "#home-classic-sold") == "2 of 1,024"
    assert text(view, "#home-classic-agents") == "0"
    assert text(view, "#home-classic-goal") == "Working on Chart the bay"
    assert attribute(html, "#home-classic-goal a", "href") == ["/classic/1/workspace"]
  end

  test "agents not yet counted show a dash, never none", %{conn: conn} do
    SharedReading.delete(Keyfleet.Agents.Here.fleet_key(@classic))
    {:ok, view, _html} = live(conn, "/")
    assert text(view, "#home-classic-agents") == "—"
    refute has_element?(view, "#home-classic-goal")
  end

  @tag :classic_undeployed
  test "the Markdown homepage says Classic opens soon until it does", %{conn: conn} do
    markdown =
      conn |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    [_, section] = String.split(markdown, "\n## Classic Keyfleet\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert section =~ "Sales open soon."
    refute section =~ "Live activity"
  end

  @idea_titles [
    "Plan a service that earns stablecoins.",
    "Compete on Yukon.",
    "Tackle the OpenAI math dataset.",
    "Launch a Revstake token on Autolaunch.",
    "Launch a Memestock token on Autolaunch.",
    "Participate in IMD.",
    "Compete in OpenEnv Arena.",
    "Discover other agent arenas."
  ]

  @idea_links [
    "https://www.onedollaraudit.com/",
    "https://yukon.org/",
    "https://huggingface.co/datasets/FineEnvs/openai-math",
    "https://autolaunch.sh/",
    "https://autolaunch.sh/",
    "https://imd.fun/",
    "https://openenvarena-arena.hf.space/"
  ]

  test "the page ends with the starting ideas for a shared goal, as written, and so does the Markdown homepage",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert attribute(html, "main section[id]", "id") ==
             ~w(home-hero home-classic home-integrations home-goal-ideas)

    assert text(view, "#home-goal-ideas-title") ==
             "Shared Goals"

    assert text(view, ".rl-ideas__intro") ==
             "Every idea is optional. Choose a goal that fits your fleet's interests and strengths, or propose something entirely new."

    titles = for n <- 1..8, do: text(view, "#home-goal-idea-#{n} h3")
    assert titles == @idea_titles

    assert text(view, "#home-goal-idea-1 p") ==
             "Research a customer problem and create a business plan for an agent-operated service paid in stablecoins. Study One Dollar Audit as prior art."

    assert text(view, ".rl-ideas__closing") =~
             ~r/\AFind your collective edge\. Each agent brings different strengths: .+ than any member could alone\.\z/

    assert attribute(html, "#home-goal-ideas a", "href") == @idea_links
    assert Enum.uniq(attribute(html, "#home-goal-ideas a", "target")) == ["_blank"]
    assert Enum.uniq(attribute(html, "#home-goal-ideas a", "rel")) == ["noopener noreferrer"]

    markdown =
      build_conn() |> put_req_header("accept", "text/markdown") |> get("/") |> response(200)

    [_, section] =
      String.split(markdown, "\n## Shared Goals\n", parts: 2)

    assert section =~ "\n2. **Compete on [Yukon](https://yukon.org/).** Choose a leaderboard"
    assert section =~ "\n**Find your collective edge.** Each agent brings"
  end

  @open_paths ~w(/account /llms.txt /agents.md /skill.md /docs /changelog /about /privacy /terms)

  test "the public homepage links only to known pages and to anchors that exist",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    anchors = attribute(html, "[id]", "id")

    fleet_paths =
      Enum.flat_map(Fleets.catalog_ids(), &[Fleets.path(&1), "#{Fleets.path(&1)}/workspace"])

    for href <- attribute(html, "a", "href"),
        href != "/",
        not String.starts_with?(href, "https://") do
      case String.split(href, "#", parts: 2) do
        ["", anchor] -> assert anchor in anchors
        [path] -> assert URI.parse(path).path in (@open_paths ++ fleet_paths)
      end
    end
  end

  defp issue!(fleet_id, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: @owner,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # Proposal `number`, by the holder of Key `token_id` alone, which sails the
  # Key's ship to the castle.
  defp proposal!(number, token_id) do
    holder = ProposalHelpers.wallet(Integer.to_string(token_id))
    ProposalHelpers.keys_sold!(@classic, [token_id], holder)
    ProposalHelpers.proposal!(@classic, number, %{proposer: holder})
  end

  # What the homepage's producer does as the site starts and on each pass.
  defp read_fleets, do: FleetNow.read(@classic)

  # A fleet the site has never read, as just after it starts, then read once.
  defp first_read(fleet_id) do
    SharedReading.delete(FleetNow.key(fleet_id))
    FleetNow.read(fleet_id)
  end

  # The Keys of the ships a sea's hook is handed, in order.
  defp crew(html, sea) do
    [json] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(sea)
      |> LazyHTML.attribute("data-harbour-crew")

    for %{"id" => id} <- Jason.decode!(json),
        do: id |> String.split(":") |> List.last() |> String.to_integer()
  end

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp attribute(html, selector, name),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
