defmodule KeyfleetWeb.Security.InjectionProbesTest do
  @moduledoc """
  Authorized red-team regression probes for external injection: stored XSS in
  agent-authored text, the content security policy's hardening invariants, and
  the one off-site redirect surface.

  Each probe asserts the safe outcome. The security pass records, per probe,
  the local toggle that disables the guard so the attack succeeds — see
  `priv/security/redteam_checks.yml` and `docs/security/redteam-2026-10-17.md`.
  """
  use ExUnit.Case, async: true

  alias KeyfleetWeb.ContentSecurityPolicy, as: CSP

  @xss_payloads [
    ~S|<script>alert(document.cookie)</script>|,
    ~S|<img src=x onerror="alert(1)">|,
    ~S|<a href="javascript:alert(1)">tap</a>|,
    ~S|<svg/onload=alert(1)>|,
    ~S|<iframe src="https://evil.example"></iframe>|,
    ~S|[click](javascript:alert(1))|,
    ~S|<a href="data:text/html,<script>alert(1)</script>">x</a>|
  ]

  # A payload left as text comes back escaped (`&lt;img … onerror=…&gt;`), which
  # is safe, so the handler and scheme checks look inside a real tag.
  describe "stored XSS — a room post's words are rendered as safe HTML (RT-XSS-ROOMS)" do
    # Toggle to break: in rooms_live.ex `@markdown`, set `sanitize: []` or add
    # `render: [unsafe_: true]`; the payload then reaches the page unescaped.
    test "no agent-authored payload produces an executable tag or scheme" do
      for payload <- @xss_payloads do
        html = payload |> KeyfleetWeb.RoomsLive.body_html() |> safe_to_string()

        refute html =~ ~r/<script/i, "script tag survived: #{inspect(payload)}"
        refute html =~ ~r/<iframe/i, "iframe survived: #{inspect(payload)}"
        refute html =~ ~r/<svg/i, "svg survived: #{inspect(payload)}"

        refute html =~ ~r/<[a-z][^>]*[\s\/]on\w+\s*=/i,
               "event handler survived: #{inspect(payload)}"

        refute html =~ ~r/<[a-z][^>]*\s(href|src)\s*=\s*"?\s*javascript:/i,
               "javascript: scheme survived: #{inspect(payload)}"

        refute html =~ ~r/<[a-z][^>]*\s(href|src)\s*=\s*"?\s*data:text\/html/i,
               "data:text/html survived: #{inspect(payload)}"
      end
    end

    test "a plain link keeps noopener and an allowed scheme" do
      html =
        "[docs](https://example.com)" |> KeyfleetWeb.RoomsLive.body_html() |> safe_to_string()

      assert html =~ ~s(href="https://example.com")
      assert html =~ "noopener"
    end
  end

  describe "stored XSS — public Markdown documents render as safe HTML (RT-XSS-DOCS)" do
    # Toggle to break: in public_documents.ex, drop the `sanitize:` option from
    # `MDEx.to_html!/2`.
    test "no payload in committed/agent markdown produces an executable tag" do
      for payload <- @xss_payloads do
        html = payload |> KeyfleetWeb.PublicDocuments.html() |> safe_to_string()
        refute html =~ ~r/<script/i, inspect(payload)
        refute html =~ ~r/<[a-z][^>]*[\s\/]on\w+\s*=/i, inspect(payload)
        refute html =~ ~r/<[a-z][^>]*\s(href|src)\s*=\s*"?\s*javascript:/i, inspect(payload)
      end
    end
  end

  describe "content security policy keeps its hardening invariants (RT-CSP)" do
    # Toggle to break: add `'unsafe-inline'`/`'unsafe-eval'` to `script-src`, or
    # widen `default-src`/`frame-ancestors`, in content_security_policy.ex.
    # Policies are evaluated at runtime (sign_in/0 reads picture-bucket config).
    test "no profile allows unsafe-inline, unsafe-eval or a wildcard on script-src" do
      for policy <- [CSP.reading(), CSP.sign_in()] do
        script_src = directive(policy, "script-src")
        refute "'unsafe-inline'" in script_src, policy
        refute "'unsafe-eval'" in script_src, policy
        refute Enum.any?(script_src, &String.contains?(&1, "*")), policy
      end
    end

    test "every profile locks default-src, base-uri and framing" do
      for policy <- [CSP.reading(), CSP.sign_in()] do
        assert directive(policy, "default-src") == ["'none'"], policy
        assert directive(policy, "frame-ancestors") == ["'none'"], policy
        assert directive(policy, "base-uri") == ["'none'"], policy
        # object-src is unset and falls back to default-src 'none'.
        assert directive(policy, "object-src") in [[], ["'none'"]], policy
      end
    end
  end

  describe "off-site redirect — the notebook open destination is bounded (RT-REDIRECT)" do
    # Toggle to break: in Keyfleet.Notebooks, make `destination?/1` return true
    # for arbitrary strings; `notebook_open_controller` would then redirect off
    # site.
    test "only the start page or a saved-output path is an allowed destination" do
      assert Keyfleet.Notebooks.destination?("/")

      for hostile <- [
            "https://evil.example",
            "//evil.example",
            "http://169.254.169.254/latest/meta-data/",
            "javascript:alert(1)",
            "/../../etc/passwd",
            "\\\\evil.example"
          ] do
        refute Keyfleet.Notebooks.destination?(hostile), inspect(hostile)
      end
    end
  end

  defp directive(policy, name) do
    policy
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value([], fn segment ->
      case String.split(segment, " ", trim: true) do
        [^name | sources] -> sources
        _ -> false
      end
    end)
  end

  defp safe_to_string(safe), do: safe |> Phoenix.HTML.safe_to_string()
end
