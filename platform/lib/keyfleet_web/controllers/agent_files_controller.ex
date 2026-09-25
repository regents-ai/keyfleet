defmodule KeyfleetWeb.AgentFilesController do
  @moduledoc """
  The files an agent needs to join, served from the site itself: the joining
  guide at `/skill.md` and `/.well-known/skills/keyfleet/SKILL.md`, the skills
  index at `/.well-known/skills/index.json`, and the SIWA sign-in clients at
  `/agent/siwa_agent.py` and `/agent/siwa-agent.mjs`.

  Every file is read when the application is compiled. The guide's
  `{{siwa_agent_py_sha256}}` and `{{siwa_agent_mjs_sha256}}` become the
  clients' sha256 digests in hex from `priv/agent/clients.lock`; its `{{origin}}` and
  `{{siwa_origin}}` become this site's address and the sign-in server it
  trusts. Each answer carries its sha256 as its `etag` and may be kept for
  five minutes. Nothing here reads the database.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.PublicDocuments

  @guide_path Application.app_dir(:keyfleet, "priv/public/skill.md")
  @lock_path Application.app_dir(:keyfleet, "priv/agent/clients.lock")
  @client_paths Map.new(
                  ~w(siwa_agent.py siwa-agent.mjs),
                  &{&1, Application.app_dir(:keyfleet, "priv/agent/#{&1}")}
                )
  for path <- [@guide_path, @lock_path | Map.values(@client_paths)],
      do: @external_resource(path)

  @digests @lock_path |> File.read!() |> Jason.decode!() |> Map.fetch!("files")
  @clients Map.new(@client_paths, fn {file, path} -> {file, File.read!(path)} end)

  # The guide prints each digest as `sha256sum` and `shasum -a 256` print it.
  hex = &String.replace_prefix(&1, "sha256:", "")

  @guide @guide_path
         |> File.read!()
         |> String.replace("{{siwa_agent_py_sha256}}", hex.(@digests["siwa_agent.py"]))
         |> String.replace("{{siwa_agent_mjs_sha256}}", hex.(@digests["siwa-agent.mjs"]))

  [_, frontmatter, _] = String.split(@guide, "---\n", parts: 3)
  @skill YamlElixir.read_from_string!(frontmatter)

  @index Jason.encode!(%{
           skills: [
             %{name: @skill["name"], description: @skill["description"], files: ["SKILL.md"]}
           ]
         })

  @doc "The joining guide as it is served, with this site's addresses in it."
  def guide do
    siwa_origin = to_string(Application.get_env(:keyfleet, :siwa_broker_url))

    @guide
    |> String.replace("{{siwa_origin}}", siwa_origin)
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

  def python_client(conn, _params) do
    client = @clients["siwa_agent.py"]
    conn |> cached(client) |> put_resp_content_type("text/x-python") |> send_resp(200, client)
  end

  def node_client(conn, _params) do
    client = @clients["siwa-agent.mjs"]
    conn |> cached(client) |> put_resp_content_type("text/javascript") |> send_resp(200, client)
  end

  defp cached(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
  end
end
