defmodule KeyfleetWeb.EarlyControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts.RequestRateLimiter
  alias Keyfleet.Actors.System
  alias Keyfleet.Early.Signup
  alias KeyfleetWeb.ContentSecurityPolicy

  @joined "You're on the list. We'll email you when Keyfleet opens."
  @unreadable "Enter an email address, like name@example.com."
  @too_long "That address is too long: 254 characters at most."
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
             "Every Key comes on its own card: eight random traits, Common to Mythic."

    assert text(page, "main") =~
             "Keyfleet opens soon. Leave your email and we'll tell you when it does."

    assert text(page, "label[for=early-email]") == "Email"

    assert page |> LazyHTML.query("input#early-email") |> LazyHTML.attribute("inputmode") ==
             ["email"]

    assert text(page, "button[type=submit]") == "Tell me when it opens"

    assert page |> LazyHTML.query("footer a") |> LazyHTML.attribute("href") ==
             ["https://x.com/regents_sh", "/privacy", "/terms"]

    assert text(page, "footer a[href='https://x.com/regents_sh']") == "Follow on X"
  end

  test "the page shows the tech stack under the form" do
    page = build_conn() |> get("/early") |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "details#early-tech-stack:not([open]) .rg-disclosure-title") == "Tech stack"

    assert page |> LazyHTML.query("#early-tech-stack li") |> Enum.map(&LazyHTML.text/1) == [
             "Bring your own agent: Hermes, OpenAI Dots, Muse, Grok Bot.",
             "The agents collaborate between marimo notebooks, Activegraph.ai, and Git.",
             "Private chat rooms, and direct messages to other agents in their fleet.",
             "Keys are owned and transferable on Base, and give treasury rights."
           ]
  end

  test "the page offers a key to roll" do
    page = build_conn() |> get("/early") |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "#roller-title") == "Example Key"
    assert text(page, "#key-roller button[type=button]") == "Roll an example Key"
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

  # Costly failure: a person who pastes too much into the field gets a bare
  # error page in place of the form's own words.
  test "the most the field takes, in letters the form encodes longest, is answered by the form" do
    page = build_conn() |> get("/early") |> html_response(200) |> LazyHTML.from_document()
    [most] = page |> LazyHTML.query("#early-email") |> LazyHTML.attribute("maxlength")

    # Three bytes each, nine characters each once the form encodes them.
    longest = String.duplicate("€", String.to_integer(most))
    page = %{"email" => longest} |> sign_up() |> html_response(422) |> LazyHTML.from_document()

    assert text(page, "#early-email-errors") == @too_long
    assert emails() == []
  end

  # Costly failure: an address cut by the field to one that reads as an
  # address is kept, and nobody hears from the address that was pasted.
  test "an address the field cut is refused as too long, and one it holds whole is kept" do
    cut = "ada@example.com" <> String.duplicate(" ", 240)
    assert %{"email" => cut} |> sign_up() |> html_response(422) =~ "too long"
    assert emails() == []

    kept = String.duplicate("a", 240) <> "@example.com"
    assert redirected_to(sign_up(%{"email" => kept})) == "/early"
    assert emails() == [kept]
  end

  # Everything typed in the field counts toward its most, so the longest
  # address with anything typed before or after it is too long.
  test "the longest address is kept, and with a space, tab or no-break space around it refused" do
    longest = String.duplicate("a", 254 - byte_size("@example.com")) <> "@example.com"

    for {typed, client} <- [
          {" " <> longest, "198.51.100.21"},
          {longest <> " ", "198.51.100.22"},
          {"\t" <> longest, "198.51.100.23"},
          {<<0xA0::utf8>> <> longest, "198.51.100.24"}
        ] do
      assert %{"email" => typed} |> sign_up(client) |> html_response(422) =~ "too long"
    end

    assert emails() == []
    assert redirected_to(sign_up(%{"email" => longest}, "198.51.100.25")) == "/early"
    assert emails() == [longest]
  end

  # Costly failure: an address with a character in it that shows as nothing
  # is kept as typed, so the same person is on the list twice and the kept
  # address may never reach them.
  test "an address with a space or an unseen character inside or before it is not an address" do
    for {typed, client} <- [
          {<<0x200B::utf8>> <> "ada@example.com", "198.51.100.31"},
          {<<0xFEFF::utf8>> <> "ada@example.com", "198.51.100.32"},
          {"ada@exa" <> <<0x2060::utf8>> <> "mple.com", "198.51.100.33"},
          {"ada" <> <<0xA0::utf8>> <> "@example.com", "198.51.100.34"},
          {"ada@example" <> <<0x3164::utf8>> <> ".com", "198.51.100.35"}
        ] do
      page =
        %{"email" => typed} |> sign_up(client) |> html_response(422) |> LazyHTML.from_document()

      assert text(page, "#early-email-errors") == @unreadable
    end

    assert emails() == []
    assert redirected_to(sign_up(%{"email" => "ada@example.com"}, "198.51.100.36")) == "/early"
    assert emails() == ["ada@example.com"]
  end

  # Costly failure: one person is on the list twice, under the Unicode and
  # the ASCII spelling of one host, and the Unicode one may not be mailable.
  test "a host is kept in its ASCII form, so both spellings of an address are one entry" do
    for {typed, client} <- [
          {"ada@bücher.de", "198.51.100.41"},
          {"Ada@BÜCHER.DE", "198.51.100.42"},
          {"ada@xn--bcher-kva.de", "198.51.100.43"}
        ] do
      assert redirected_to(sign_up(%{"email" => typed}, client)) == "/early"
    end

    assert emails() == ["ada@xn--bcher-kva.de"]
  end

  test "a host with ß keeps its ß, apart from the same host written with ss" do
    assert redirected_to(sign_up(%{"email" => "ada@faß.de"}, "198.51.100.44")) == "/early"
    assert redirected_to(sign_up(%{"email" => "ada@fass.de"}, "198.51.100.45")) == "/early"

    assert Enum.sort(emails()) == ["ada@fass.de", "ada@xn--fa-hia.de"]
  end

  test "a host that can't be written in ASCII is not an address" do
    for {typed, client} <- [
          {"ada@☃.net", "198.51.100.51"},
          {"ada@" <> <<0x0301::utf8>> <> "a.com", "198.51.100.52"},
          {"ada@" <> String.duplicate("a", 64) <> ".com", "198.51.100.53"},
          {"ada@foo_bar.com", "198.51.100.54"},
          # An empty first part, which the ASCII rules would drop, keeping
          # another address.
          {"ada@.bücher.de", "198.51.100.55"},
          {"ada@bücher..de", "198.51.100.56"},
          {"ada@example.com.", "198.51.100.59"}
        ] do
      page =
        %{"email" => typed} |> sign_up(client) |> html_response(422) |> LazyHTML.from_document()

      assert text(page, "#early-email-errors") == @unreadable
    end

    assert emails() == []
  end

  # The 254 bytes hold the address as stored, as well as as typed.
  test "an address that fits as typed but not once its host is in ASCII is refused" do
    over = String.duplicate("a", 238) <> "@bücher.de"
    page = %{"email" => over} |> sign_up("198.51.100.57") |> html_response(422)

    assert page |> LazyHTML.from_document() |> text("#early-email-errors") == @unreadable
    assert emails() == []

    fits = String.duplicate("a", 237) <> "@bücher.de"
    assert redirected_to(sign_up(%{"email" => fits}, "198.51.100.58")) == "/early"
    assert emails() == [String.duplicate("a", 237) <> "@xn--bcher-kva.de"]
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

  # Sends the form as a browser does: with the token from the page it was on,
  # from the client address Fly's proxy names.
  defp sign_up(params, client \\ "198.51.100.7") do
    page = build_conn() |> put_req_header("fly-client-ip", client) |> get("/early")

    [token] =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body, capture: :all_but_first)

    page
    |> recycle()
    |> put_req_header("fly-client-ip", client)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/early", URI.encode_query(Map.put(params, "_csrf_token", token)))
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
