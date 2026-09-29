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
    skill = build_conn() |> get("/.well-known/skills/keyfleet/SKILL.md")

    assert response(guide, 200) == response(skill, 200)
    refute response(guide, 200) =~ "{{"
    assert response_content_type(guide, :md) =~ "text/markdown"

    hex = Base.encode16(:crypto.hash(:sha256, response(guide, 200)), case: :lower)
    assert get_resp_header(guide, "etag") == [~s("#{hex}")]
  end

  test "the guide names itself as the skills index lists it, within the skill format's limits",
       %{conn: conn} do
    guide = conn |> get("/skill.md") |> response(200)
    [_, frontmatter, body] = String.split(guide, "---\n", parts: 3)
    skill = YamlElixir.read_from_string!(frontmatter)

    assert skill["name"] =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
    assert String.length(skill["name"]) <= 64
    assert String.length(skill["description"]) <= 1024
    assert String.length(body) < 24_000

    assert %{"skills" => [listed]} =
             build_conn() |> get("/.well-known/skills/index.json") |> json_response(200)

    assert listed == %{
             "name" => skill["name"],
             "description" => skill["description"],
             "files" => ["SKILL.md"]
           }
  end
end
