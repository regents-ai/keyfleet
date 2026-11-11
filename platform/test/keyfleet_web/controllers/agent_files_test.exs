defmodule KeyfleetWeb.AgentFilesTest do
  use KeyfleetWeb.ConnCase, async: true

  test "the guide sends agents to the sign-in server for the client and its guide",
       %{conn: conn} do
    guide = conn |> get("/skill.md") |> response(200)
    siwa = Application.fetch_env!(:keyfleet, :siwa_broker_url)

    assert guide =~ "curl -fsSO #{siwa}/agent/siwa_agent.py"
    assert guide =~ "#{siwa}/skill.md"
  end

  test "the guide is the same at both of its addresses, with every placeholder filled in",
       %{conn: conn} do
    guide = conn |> get("/skill.md")
    skill = build_conn() |> get("/.well-known/agent-skills/keyfleet/SKILL.md")

    assert response(guide, 200) == response(skill, 200)
    refute response(guide, 200) =~ "{{"
    assert response_content_type(guide, :md) =~ "text/markdown"

    hex = Base.encode16(:crypto.hash(:sha256, response(guide, 200)), case: :lower)
    assert get_resp_header(guide, "etag") == [~s("#{hex}")]
  end

  test "the agent access page has the table of who may do what, open or closed as the site is, and the guide points there",
       %{conn: conn} do
    table =
      Keyfleet.Authority.markdown_table(KeyfleetWeb.Plugs.LaunchGate.app_surfaces_enabled?())

    assert conn |> get("/agents.md") |> response(200) =~ table

    assert build_conn() |> get("/skill.md") |> response(200) =~
             "Check who may do what (#{KeyfleetWeb.Endpoint.url()}/agents.md)"
  end

  test "agents read which fleets are open and that Classic #1 sells its Keys", %{conn: conn} do
    open = "The Regents Club and Classic #1 are open"

    assert conn |> get("/llms.txt") |> response(200) =~ open
    assert build_conn() |> get("/llms.txt") |> response(200) =~ "Classic #1 sells its 1,024 Keys"
    assert build_conn() |> get("/docs") |> html_response(200) =~ open

    assert build_conn()
           |> put_req_header("accept", "text/markdown")
           |> get("/about")
           |> response(200) =~ open
  end

  test "every guide a new agent reads ends with the starting ideas for a shared goal, and the joining guide points there",
       %{conn: conn} do
    ideas = "#" <> File.read!("priv/public/goal-ideas.md")

    assert String.starts_with?(
             ideas,
             "## Shared Goals\n"
           )

    assert ideas =~ "\n8. **Discover other agent arenas.** "
    assert ideas =~ "\n**Find your collective edge.** "

    assert conn |> get("/agents.md") |> response(200) |> String.ends_with?(ideas)

    # Claude's guide is served only while the Claude connector is on.
    slugs = for {slug, _name} <- KeyfleetWeb.AgentGuides.runtimes(), do: slug
    assert "dots" in slugs

    for slug <- slugs do
      page =
        build_conn()
        |> put_req_header("accept", "text/markdown")
        |> get("/agents/#{slug}")
        |> response(200)

      assert String.ends_with?(page, ideas), "/agents/#{slug} lacks the ideas"

      assert build_conn()
             |> get("/agents/#{slug}/skill.md")
             |> response(200)
             |> String.ends_with?(ideas),
             "/agents/#{slug}/skill.md lacks the ideas"
    end

    page = build_conn() |> get("/agents/dots") |> html_response(200)

    headings =
      page |> LazyHTML.from_document() |> LazyHTML.query("h2") |> Enum.map(&LazyHTML.text/1)

    assert "Shared Goals" in Enum.map(
             headings,
             &String.trim/1
           )

    assert page =~ ~r{<strong>Compete on <a href="https://yukon.org/"[^>]*>Yukon</a>.</strong>}

    assert build_conn() |> get("/skill.md") |> response(200) =~
             "or join a task, or join a starting goal once a Key takes `general` over."
  end

  test "the guide names itself as the skills index lists it, within the skill format's limits",
       %{conn: conn} do
    guide = conn |> get("/skill.md") |> response(200)
    [_, frontmatter, _body] = String.split(guide, "---\n", parts: 3)
    skill = YamlElixir.read_from_string!(frontmatter)

    assert skill["name"] =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
    assert String.length(skill["name"]) <= 64
    assert String.length(skill["description"]) <= 1024
    # Measured whole, as the live site serves it under its own address.
    live_guide = String.replace(guide, KeyfleetWeb.Endpoint.url(), "https://keyfleet.ai")
    assert String.length(live_guide) < 9_000

    assert %{"skills" => [listed]} =
             build_conn() |> get("/.well-known/agent-skills/index.json") |> json_response(200)

    assert %{"name" => name, "description" => description, "type" => "archive"} = listed
    assert {name, description} == {skill["name"], skill["description"]}
  end

  test "the guide links the parts it leaves out, and each part answers with its addresses filled in",
       %{conn: conn} do
    guide = conn |> get("/skill.md") |> response(200)
    origin = Regex.escape(KeyfleetWeb.Endpoint.url())
    parts = for [_, path] <- Regex.scan(~r{#{origin}(/skill/[a-z]+\.md)}, guide), do: path

    assert parts == ~w(/skill/code.md /skill/notebooks.md /skill/decide.md)

    for path <- parts do
      part = build_conn() |> get(path)
      body = response(part, 200)

      assert response_content_type(part, :md) =~ "text/markdown"
      assert body =~ "#{KeyfleetWeb.Endpoint.url()}/skill.md"
      refute body =~ "{{"
    end

    assert_error_sent 404, fn -> build_conn() |> get("/skill/missing.md") end
  end

  test "the skills index names a zip whose digest matches, holding the guide as it is served",
       %{conn: conn} do
    guide = conn |> get("/skill.md") |> response(200)

    assert %{"$schema" => "https://schemas.agentskills.io/discovery/0.2.0/schema.json"} =
             index =
             build_conn() |> get("/.well-known/agent-skills/index.json") |> json_response(200)

    [%{"url" => url, "digest" => "sha256:" <> digest}] = index["skills"]
    zip = build_conn() |> get(url)

    assert Base.encode16(:crypto.hash(:sha256, response(zip, 200)), case: :lower) == digest
    assert get_resp_header(zip, "content-type") == ["application/zip"]

    assert {:ok, [{~c"SKILL.md", ^guide}]} =
             :zip.extract(response(zip, 200), [:memory])
  end

  test "the command list is served as JSON, the same bytes as cli/commands.json", %{conn: conn} do
    commands = conn |> get("/commands.json")

    assert response(commands, 200) ==
             File.read!(Path.expand("../../../../cli/commands.json", __DIR__))

    assert response_content_type(commands, :json) =~ "application/json"
  end

  test "/help says what Keyfleet is and links each agent file, every link answering",
       %{conn: conn} do
    help = conn |> get("/help")
    body = response(help, 200)
    assert response_content_type(help, :md) =~ "text/markdown"

    paths = for [_, url] <- Regex.scan(~r/\]\(([^)]+)\)/, body), do: URI.parse(url).path

    assert paths ==
             ~w(/skill.md /skill/code.md /skill/notebooks.md /skill/decide.md /agents /docs /fleets.md /api-contract.openapiv3.yaml /commands.json)

    for path <- paths do
      assert build_conn()
             |> put_req_header("accept", "text/markdown")
             |> get(path)
             |> response(200),
             path
    end
  end

  test "every agent in Pair New Agent is sent to a setup page that answers, and agents that share a computer each keep their own key" do
    messages =
      for harness <- RegentAgents.Harness.featured(),
          do: {harness, KeyfleetWeb.PairingBox.agent_message("CODE", harness, nil)}

    for {harness, message} <- messages do
      [_, path] = Regex.run(~r{Your full setup: https?://[^/]+(/agents/[a-z-]+)$}, message)

      assert build_conn() |> get(path) |> response(200), "#{harness} is sent to #{path}"
    end

    homes =
      for {_harness, message} <- messages,
          [_, home] <- Regex.scan(~r{SIWA_AGENT_HOME=(\S+?)[ ,]}, message),
          do: home

    assert homes == Enum.uniq(homes)
  end
end
