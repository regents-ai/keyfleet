defmodule KeyfleetWeb.ContentSecurityPolicyTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System
  alias KeyfleetWeb.ContentSecurityPolicy

  test "a signed-in page carries the sign-in policy", %{conn: conn} do
    assert {:ok, account} =
             Accounts.register_verified(
               "did:privy:csp-signed-in",
               "0x3333333333333333333333333333333333333333",
               ["0x3333333333333333333333333333333333333333"],
               actor: %System{}
             )

    conn = conn |> init_test_session(%{human_account_id: account.id}) |> get("/account")

    assert html_response(conn, 200) =~ ~s(id="app-shell")
    assert policy(conn) == ContentSecurityPolicy.sign_in()
  end

  # The reading pages are in the app shell, with its account button.
  test "every page with the account button carries the sign-in policy and the default referrer" do
    for path <-
          ~w(/ /account /about /opportunities /docs /changelog /agents /agents/dots /privacy /terms /syndicate/1) do
      conn = get(build_conn(), path)

      assert conn.status == 200, "#{path} answered #{conn.status}"
      assert policy(conn) == ContentSecurityPolicy.sign_in(), "#{path} has another policy"

      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"],
             path
    end
  end

  test "Markdown, the fleet directory's and a reading page's, carries the reading policy" do
    for conn <- [
          get(build_conn(), "/fleets.md"),
          build_conn() |> put_req_header("accept", "text/markdown") |> get("/docs")
        ] do
      assert conn.status == 200, "#{conn.request_path} answered #{conn.status}"
      assert policy(conn) == ContentSecurityPolicy.reading(), "#{conn.request_path}"
    end
  end

  test "the reading policy names no other site but ENS pictures, and sign-in adds Privy's sources and Key cards" do
    reading = directives(ContentSecurityPolicy.reading())
    assert reading["img-src"] == ["'self'", "data:", "https://metadata.ens.domains"]

    refute ContentSecurityPolicy.reading() |> String.replace("https://metadata.ens.domains", "") =~
             "://"

    refute ContentSecurityPolicy.reading() =~ "'unsafe-eval'"

    sign_in = directives(ContentSecurityPolicy.sign_in())
    assert "https://auth.privy.io" in sign_in["connect-src"]
    assert "https://auth.privy.io" in sign_in["frame-src"]
    assert "https://media.regents.sh" in sign_in["img-src"]
    assert sign_in["frame-ancestors"] == ["'none'"]
    refute ContentSecurityPolicy.sign_in() =~ "'unsafe-eval'"
  end

  defp policy(conn) do
    [policy] = get_resp_header(conn, "content-security-policy")
    policy
  end

  defp directives(policy) do
    policy
    |> String.split("; ")
    |> Map.new(fn directive ->
      [name | sources] = String.split(directive, " ")
      {name, sources}
    end)
  end
end
