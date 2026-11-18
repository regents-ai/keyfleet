defmodule KeyfleetWeb.BodyLimitsTest do
  # Costly failure: the site decodes a body at an address that reads none, so
  # a hundred anonymous requests of under a megabyte each take gigabytes (a
  # 781 KiB JSON list took about 29 MB to decode), or a route that reads one
  # decodes more, or another kind, than it takes. Served on a real port, as a
  # visitor's request arrives.
  use ExUnit.Case, async: false

  alias KeyfleetWeb.SignedAgentHelpers

  @json "application/json"
  @form "application/x-www-form-urlencoded"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    connector = Application.fetch_env!(:keyfleet, Keyfleet.OAuth)
    Application.put_env(:keyfleet, Keyfleet.OAuth, Keyword.put(connector, :enabled?, true))
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.OAuth, connector) end)

    %{site: SignedAgentHelpers.serve_site!(:site).url}
  end

  test "a body sent where no route reads one is never decoded", c do
    # Each body would be refused as unreadable (400) if it were decoded.
    answers =
      for path <- ["/", "/nope", "/api/v1/nope", "/api/v1/fleets", "/auth/privy/session"],
          {type, body} <- [{@json, "{"}, {@form, "%zz"}],
          do: {path, type, post!(c.site, path, [{"content-type", type}], body).status}

    assert answers == [
             {"/", @json, 404},
             {"/", @form, 404},
             {"/nope", @json, 404},
             {"/nope", @form, 404},
             {"/api/v1/nope", @json, 404},
             {"/api/v1/nope", @form, 404},
             {"/api/v1/fleets", @json, 404},
             {"/api/v1/fleets", @form, 404},
             {"/auth/privy/session", @json, 403},
             {"/auth/privy/session", @form, 403}
           ]
  end

  test "each route that reads a body decodes the one kind it takes, up to its size", c do
    session = forms_session(c.site)

    # The connector's address reads a body only once the request says who
    # sends it; this one's signature reaches a stand-in sign-in server, which
    # refuses it.
    SignedAgentHelpers.start_broker!(self(), :crypto.strong_rand_bytes(32))
    signed = [{Siwa.Contract.signature_input_header(), "sig1=()"}]

    routes = [
      {"/oauth/register", @json, 8192, []},
      {"/oauth/token", @form, 8192, []},
      {"/oauth/revoke", @form, 8192, []},
      {"/oauth/authorize", @form, 256, []},
      {"/oauth/connections/revoke", @form, 256, []},
      {"/api/agents/v1/pair", @json, 4096, []},
      {"/mcp", @json, 742 * 1024, signed},
      {"/visit-log", @json, 16 * 1024, session},
      {"/auth/privy/failure", @json, 64, session}
    ]

    for {path, type, limit, headers} <- routes do
      assert answers(c.site, path, type, limit, headers) == {path, :taken, 413, 415}
    end

    # The early-access form is served only while the site is closed.
    Application.put_env(:keyfleet, :app_surfaces, false)
    on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, true) end)
    assert answers(c.site, "/early", @form, 4096, []) == {"/early", :taken, 413, 415}
  end

  # Costly failure: the page's sign-in failure report is refused with the
  # site's HTML error page, where its contract names a code in JSON.
  test "a sign-in failure report refused for its size or kind names the contract's code", c do
    session = forms_session(c.site)

    over =
      post!(c.site, "/auth/privy/failure", [{"content-type", @json} | session], body(@json, 65))

    other =
      post!(
        c.site,
        "/auth/privy/failure",
        [{"content-type", @form} | session],
        "reason=flow_closed"
      )

    assert {413, %{"error" => %{"code" => "request_entity_too_large"}}} = {over.status, over.body}
    assert {415, %{"error" => %{"code" => "unsupported_media_type"}}} = {other.status, other.body}
  end

  # A body of exactly `limit` bytes of the route's kind, one byte more, and
  # one of the other kind.
  defp answers(site, path, type, limit, headers) do
    other = if type == @json, do: @form, else: @json

    sent = fn type, size ->
      post!(site, path, [{"content-type", type} | headers], body(type, size)).status
    end

    exact = sent.(type, limit)

    {path, if(exact in [413, 415], do: exact, else: :taken), sent.(type, limit + 1),
     sent.(other, 16)}
  end

  defp body(@json, size), do: ~s({"x":") <> String.duplicate("a", size - 8) <> ~s("})
  defp body(@form, size), do: "x=" <> String.duplicate("a", size - 2)

  # A browser's session cookie and the forms token its pages send.
  defp forms_session(site) do
    response = Req.get!(site <> "/auth/csrf", retry: false)

    [cookie | _rest] =
      response |> Req.Response.get_header("set-cookie") |> hd() |> String.split(";")

    [{"cookie", cookie}, {"x-csrf-token", response.body["csrf_token"]}]
  end

  # Each on its own connection: the site closes one whose body it refused
  # unread.
  defp post!(site, path, headers, body),
    do:
      Req.post!(site <> path,
        headers: [{"connection", "close"} | headers],
        body: body,
        retry: false,
        redirect: false
      )
end
