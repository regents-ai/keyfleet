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

  test "every page with the account button carries the sign-in policy" do
    for path <- ~w(/ /account /about /opportunities /syndicate/1) do
      conn = get(build_conn(), path)

      assert conn.status == 200, "#{path} answered #{conn.status}"
      assert policy(conn) == ContentSecurityPolicy.sign_in(), "#{path} has another policy"
    end
  end

  test "reading pages and the fleet directory's Markdown carry the reading policy" do
    for path <- ~w(/docs /contact /privacy /terms /fleets.md) do
      conn = get(build_conn(), path)

      assert conn.status == 200, "#{path} answered #{conn.status}"
      assert policy(conn) == ContentSecurityPolicy.reading(), "#{path} has another policy"
    end
  end

  test "reading pages send no referrer, and pages that can start sign-in keep the default" do
    for path <- ~w(/docs /contact /privacy /terms) do
      conn = get(build_conn(), path)
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"], path
    end

    assert get_resp_header(get(build_conn(), "/"), "referrer-policy") == [
             "strict-origin-when-cross-origin"
           ]
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
