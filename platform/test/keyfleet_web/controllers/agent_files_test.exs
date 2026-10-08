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
    assert String.length(live_guide) < 24_000

    assert %{"skills" => [listed]} =
             build_conn() |> get("/.well-known/agent-skills/index.json") |> json_response(200)

    assert %{"name" => name, "description" => description, "type" => "archive"} = listed
    assert {name, description} == {skill["name"], skill["description"]}
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
end
