defmodule KeyfleetWeb.AgentFilesController do
  @moduledoc """
  The files an agent needs to join, served from the site itself: the joining
  guide at `/skill.md`, and the same guide as Keyfleet's one skill under
  `/.well-known/agent-skills/`, following Agent Skills Discovery v0.2.0
  (https://github.com/cloudflare/agent-skills-discovery-rfc). Its `index.json`
  lists the skill with its description and a zip of its folder with that zip's
  sha256 digest; the zip holds `SKILL.md`, which is also served on its own.
  Each runtime's skill, at `/agents/SLUG/skill.md`, is the guide with that
  runtime's notes from `KeyfleetWeb.AgentGuides` added.
  Agents get the SIWA sign-in client from the sign-in server, which the guide
  links. `/commands.json` is the list of `regents keyfleet` commands, read
  from `cli/commands.json` beside the platform when the application is
  compiled; a release build copies that one file in.

  The guide is read when the application is compiled. Its `{{origin}}` and
  `{{siwa_origin}}` become this site's address and the sign-in server it
  trusts, so the zip is built from the filled-in guide, with a fixed date and
  mode, and the same guide always gives the same digest. Each answer carries
  its sha256 as its `etag` and may be kept for five minutes. Nothing here
  reads the database.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.PublicDocuments

  @guide_path Application.app_dir(:keyfleet, "priv/public/skill.md")
  @external_resource @guide_path

  @guide File.read!(@guide_path)

  @commands_path Path.expand("../../../../cli/commands.json", __DIR__)
  @external_resource @commands_path
  @commands File.read!(@commands_path)

  [_, frontmatter, _] = String.split(@guide, "---\n", parts: 3)
  @skill YamlElixir.read_from_string!(frontmatter)

  @base "/.well-known/agent-skills"
  @schema "https://schemas.agentskills.io/discovery/0.2.0/schema.json"
  @epoch {{1980, 1, 1}, {0, 0, 0}}

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

  @doc """
  One runtime's skill: the joining guide with that runtime's Set up section
  from its page at `/agents/SLUG` added at the end.
  """
  def agent_skill(conn, %{"agent" => slug}) do
    case KeyfleetWeb.AgentGuides.setup(slug) do
      {name, setup} ->
        skill = guide() <> "\n## On #{name}\n\n" <> setup <> "\n"
        conn |> cached(skill) |> put_resp_content_type("text/markdown") |> send_resp(200, skill)

      nil ->
        raise KeyfleetWeb.NotFoundError
    end
  end

  def index(conn, _params) do
    index =
      Jason.encode!(
        %{
          "$schema" => @schema,
          "skills" => [
            %{
              "name" => @skill["name"],
              "type" => "archive",
              "description" => @skill["description"],
              "url" => "#{@base}/#{@skill["name"]}.zip",
              "digest" => "sha256:" <> sha256(zip())
            }
          ]
        },
        pretty: true
      )

    conn |> cached(index) |> put_resp_content_type("application/json") |> send_resp(200, index)
  end

  def commands(conn, _params) do
    conn
    |> cached(@commands)
    |> put_resp_content_type("application/json")
    |> send_resp(200, @commands)
  end

  def archive(conn, _params) do
    zip = zip()
    conn |> cached(zip) |> put_resp_content_type("application/zip", nil) |> send_resp(200, zip)
  end

  # The skill's folder as one zip: its `SKILL.md`, dated and moded the same
  # every time, so the digest the index names changes only with the guide.
  defp zip do
    body = guide()

    stat =
      File.Stat.to_record(%File.Stat{
        size: byte_size(body),
        type: :regular,
        access: :read,
        atime: @epoch,
        mtime: @epoch,
        ctime: @epoch,
        mode: 0o100644,
        links: 1,
        major_device: 0,
        minor_device: 0,
        inode: 0,
        uid: 0,
        gid: 0
      })

    {:ok, {_name, zip}} =
      :zip.create(~c"#{@skill["name"]}.zip", [{~c"SKILL.md", body, stat}], [:memory])

    zip
  end

  defp cached(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{sha256(body)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("access-control-allow-origin", "*")
  end

  defp sha256(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
end
