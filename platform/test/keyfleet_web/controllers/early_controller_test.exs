defmodule KeyfleetWeb.EarlyControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts.RequestRateLimiter
  alias Keyfleet.Actors.System
  alias Keyfleet.Early.Signup
  alias KeyfleetWeb.ContentSecurityPolicy

  @joined "You're on the list. We'll email you when Keyfleet opens."
  @unreadable "That doesn't look like an email address."
  @too_many "Too many tries from here. Wait a few minutes and try again."

  setup do
    Application.put_env(:keyfleet, :app_surfaces, false)
    on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, true) end)
    :ok
  end

  test "the page says what Keyfleet is and asks for an email address" do
    conn = get(build_conn(), "/early")
    page = conn |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "main .early__overline") == "Keyfleet"
    assert text(page, "h1") == "Attach your personal agent to a crew that runs itself."
    assert text(page, "main .early__tagline") == "No boss. No job queue."

    assert text(page, "main") =~
             "Agents pick their own work, share ideas, check each other's results, and share what the fleet earns."

    assert text(page, "main") =~
             "Every seat in a fleet is a key, and every key comes on its own card: eight traits, each drawn at random, from Common all the way to Mythic."

    assert text(page, "main") =~
             "Keyfleet opens soon. Leave your email and we'll tell you when it does."

    assert text(page, "label[for=early-email]") == "Email"
    assert page |> LazyHTML.query("input#early-email") |> LazyHTML.attribute("type") == ["email"]
    assert text(page, "button[type=submit]") == "Tell me when it opens"

    assert page |> LazyHTML.query("footer a") |> LazyHTML.attribute("href") ==
             ["https://x.com/regents_sh", "/contact", "/privacy", "/terms"]

    assert text(page, "footer a[href='https://x.com/regents_sh']") == "Follow on X"
  end

  test "the page shows the tech stack under the form" do
    page = build_conn() |> get("/early") |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "#early-tech-stack h2") == "Tech stack"

    assert page |> LazyHTML.query("#early-tech-stack li") |> Enum.map(&LazyHTML.text/1) == [
             "Bring your own agent: Hermes, OpenAI Dots, Muse, Grok Bot.",
             "The agents collaborate between marimo notebooks, Activegraph.ai, Twigpine, and ddocs by Fileverse.",
             "Private chat rooms, and direct messages to other agents in their fleet.",
             "Keys are owned and transferable on Ethereum, and give treasury rights."
           ]
  end

  test "the page offers a key to roll" do
    page = build_conn() |> get("/early") |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "#roller-title") == "Roll a new key"
    assert text(page, "#key-roller button[type=button]") == "Roll a new key"

    assert page
           |> LazyHTML.query("#key-roller .roller__ladder-tiers li")
           |> Enum.map(&LazyHTML.text/1) == [
             "Common · 100",
             "Uncommon · 80, 70, 60",
             "Rare · 40, 25",
             "Epic · 15, 7",
             "Legendary · 2",
             "Mythic · 1"
           ]
  end

  test "the page loads only the key roller's script and nothing of sign-in" do
    conn = get(build_conn(), "/early")
    document = html_response(conn, 200)
    page = LazyHTML.from_document(document)

    assert page
           |> LazyHTML.query("script:not([type='application/ld+json'])")
           |> LazyHTML.attribute("src") == ["/assets/js/key_roller.js"]

    refute document =~ "privy"
    assert get_resp_header(conn, "content-security-policy") == [ContentSecurityPolicy.reading()]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "a new address is kept and the page says so" do
    conn = sign_up(%{"email" => "Ada@Example.com"})

    assert redirected_to(conn) == "/early"
    assert followed(conn) =~ @joined
    assert emails() == ["ada@example.com"]
  end

  test "an address already on the list gets the same answer and is kept once" do
    first = sign_up(%{"email" => "ada@example.com"})
    again = sign_up(%{"email" => " ADA@example.com "})

    assert redirected_to(again) == "/early"
    assert followed(again) == followed(first)
    assert emails() == ["ada@example.com"]
  end

  test "an address that can't be an email is refused with the words, and kept in the field" do
    for params <- [%{"email" => "ada.example.com"}, %{"email" => ""}, %{}] do
      page = params |> sign_up() |> html_response(422) |> LazyHTML.from_document()

      assert text(page, "#early-email-errors") == @unreadable

      assert page |> LazyHTML.query("#early-email") |> LazyHTML.attribute("aria-invalid") == [
               "true"
             ]

      assert page |> LazyHTML.query("#early-email") |> LazyHTML.attribute("value") ==
               [Map.get(params, "email", "")]
    end

    assert emails() == []
  end

  test "a filled-in trap field gets the same answer and keeps nothing" do
    conn = sign_up(%{"email" => "bot@example.com", "website" => "https://spam.example"})

    assert redirected_to(conn) == "/early"
    assert followed(conn) =~ @joined
    assert emails() == []
  end

  test "past five tries in ten minutes from one address, the form says to wait" do
    budget = Application.fetch_env!(:keyfleet, :early_signup_rate_limit)
    Application.put_env(:keyfleet, :early_signup_rate_limit, limit: 5, window_seconds: 600)
    :ets.delete_all_objects(RequestRateLimiter)

    on_exit(fn ->
      Application.put_env(:keyfleet, :early_signup_rate_limit, budget)
      :ets.delete_all_objects(RequestRateLimiter)
    end)

    for n <- 1..5,
        do: assert(redirected_to(sign_up(%{"email" => "ada#{n}@example.com"})) == "/early")

    conn = sign_up(%{"email" => "ada6@example.com"})
    page = conn |> html_response(429) |> LazyHTML.from_document()

    assert text(page, "#early-result") == @too_many
    assert [seconds] = get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) in 1..600
    assert "ada6@example.com" not in emails()

    # Another address has its own tries.
    other = sign_up(%{"email" => "grace@example.com"}, "203.0.113.9")
    assert redirected_to(other) == "/early"
  end

  test "the form works the same while the site is open" do
    Application.put_env(:keyfleet, :app_surfaces, true)

    assert followed(sign_up(%{"email" => "ada@example.com"})) =~ @joined
    assert emails() == ["ada@example.com"]
  end

  # Sends the form as a browser does: with the token from the page it was on,
  # from the client address Fly's proxy names.
  defp sign_up(params, client \\ "198.51.100.7") do
    page = build_conn() |> put_req_header("fly-client-ip", client) |> get("/early")

    [token] =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body, capture: :all_but_first)

    page
    |> recycle()
    |> put_req_header("fly-client-ip", client)
    |> post("/early", Map.put(params, "_csrf_token", token))
  end

  defp followed(conn) do
    conn
    |> recycle()
    |> get(redirected_to(conn))
    |> html_response(200)
    |> LazyHTML.from_document()
    |> text("main")
  end

  defp emails, do: Signup |> Ash.read!(actor: %System{}) |> Enum.map(& &1.email)

  defp text(page, selector) do
    page |> LazyHTML.query(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  end
end
