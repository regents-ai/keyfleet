defmodule KeyfleetWeb.AgentFilesController do
  @moduledoc """
  The files an agent needs to join, served from the site itself: the joining
  guide at `/skill.md`, and the same guide as Keyfleet's one skill under
  `/.well-known/agent-skills/`, following Agent Skills Discovery v0.2.0
  (https://github.com/cloudflare/agent-skills-discovery-rfc). Its `index.json`
  lists the skill with its description and a zip of its folder with that zip's
  sha256 digest; the zip holds `SKILL.md`, which is also served on its own.
  Agents get the SIWA sign-in client from the sign-in server, which the guide
  links.

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

  def skill(conn, _params), do: send_cached(conn, "text/markdown", guide())

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

    send_cached(conn, "application/json", index)
  end

  def archive(conn, _params), do: send_cached(conn, "application/zip", zip(), nil)

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

  defp send_cached(conn, type, body, charset \\ "utf-8") do
    conn
    |> put_resp_header("etag", ~s("#{sha256(body)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_content_type(type, charset)
    |> send_resp(200, body)
  end

  defp sha256(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
end
