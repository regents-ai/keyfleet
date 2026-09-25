defmodule KeyfleetWeb.AgentFilesController do
  @moduledoc """
  The files an agent needs to join, served from the site itself: the joining
  guide at `/skill.md` and `/.well-known/skills/keyfleet/SKILL.md`, the skills
  index at `/.well-known/skills/index.json`, and the SIWA sign-in client at
  `/agent/siwa_agent.py`.

  Every file is read when the application is compiled. The guide's
  `{{siwa_agent_py_sha256}}` becomes the client's sha256 digest in hex from
  `priv/agent/clients.lock`; its `{{origin}}` and `{{siwa_origin}}` become this
  site's address and the sign-in server it trusts. Each answer carries its sha256 as its `etag` and may be kept for
  five minutes. Nothing here reads the database.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.PublicDocuments

  @guide_path Application.app_dir(:keyfleet, "priv/public/skill.md")
  @lock_path Application.app_dir(:keyfleet, "priv/agent/clients.lock")
  @client_path Application.app_dir(:keyfleet, "priv/agent/siwa_agent.py")
  for path <- [@guide_path, @lock_path, @client_path], do: @external_resource(path)

  @client File.read!(@client_path)

  # The guide prints the digest as `sha256sum` and `shasum -a 256` print it.
  "sha256:" <> digest =
    @lock_path |> File.read!() |> Jason.decode!() |> get_in(["files", "siwa_agent.py"])

  @guide @guide_path |> File.read!() |> String.replace("{{siwa_agent_py_sha256}}", digest)

  [_, frontmatter, _] = String.split(@guide, "---\n", parts: 3)
  @skill YamlElixir.read_from_string!(frontmatter)

  @index Jason.encode!(%{
           skills: [
             %{name: @skill["name"], description: @skill["description"], files: ["SKILL.md"]}
           ]
         })

  @doc "The joining guide as it is served, with this site's addresses in it."
  def guide do
    @guide
    |> String.replace("{{siwa_origin}}", Application.fetch_env!(:keyfleet, :siwa_broker_url))
    |> String.replace("{{origin}}", PublicDocuments.url(""))
  end

  def skill(conn, _params) do
    guide = guide()
    conn |> cached(guide) |> put_resp_content_type("text/markdown") |> send_resp(200, guide)
  end

  def index(conn, _params),
    do:
      conn
      |> cached(@index)
      |> put_resp_content_type("application/json")
      |> send_resp(200, @index)

  def python_client(conn, _params),
    do:
      conn
      |> cached(@client)
      |> put_resp_content_type("text/x-python")
      |> send_resp(200, @client)

  defp cached(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
  end
end
