defmodule KeyfleetWeb.ContentSecurityPolicy do
  @moduledoc """
  The content security policies the site's pages are served under.

  `reading/0` is the strict baseline: scripts, styles, images and fonts come
  from this site, apart from people's ENS pictures, which the ENS avatar service
  serves; requests and the live connection go back to it, no page frames
  another site or is framed itself, and forms submit only here.

  `sign_in/0` is the baseline plus exactly what Privy's wallet sign-in loads,
  taken from Privy's published policy and checked against the bundled Privy
  and WalletConnect code: Privy's API, frame and wallet RPC, Cloudflare
  Turnstile (when bot protection is on for the Privy app), WalletConnect's
  relays, verify frame, wallet list, logos, RPC and event reporting, Coinbase
  Wallet's relay, and the `blob:` images Privy's window draws. Privy's sign-in
  window writes its own style elements, so only this profile allows them.

  Pages that can sign someone in are also the pages that show agents and Keys,
  so `sign_in/0` adds to `img-src` the public origin of the bucket agents'
  pictures are served from (`Keyfleet.Agents.AvatarBucket`) and the one Key
  cards are shown from (`Keyfleet.Keys.KeyArt`). The bucket's origin is known
  only once the site starts, so this policy is built for each response.

  `showcase/0` is `sign_in/0` for the local showcase, which frames its own
  preview page. `errors/1` is the baseline plus one request's nonce, for the
  saved-errors page.

  A site that loads anything else adds each origin to the one directive and the
  one profile that needs it. The only wildcard is Privy's own `*.rpc.privy.systems`,
  from its published policy.
  """

  # The development code reloader runs in a frame from this site.
  @own_frames if Application.compile_env(:keyfleet, [KeyfleetWeb.Endpoint, :code_reloader]),
                do: ["'self'"],
                else: []

  @baseline [
    {"default-src", ["'none'"]},
    {"script-src", ["'self'"]},
    {"style-src", ["'self'"]},
    # Style attributes only, never style elements: a card, panel or dialog that is
    # moving keeps its inline style across a page update with
    # `JS.ignore_attributes(["style"])`, which LiveView puts back with one, and
    # the showcase's ratio card sizes its fill with one. Rising words and digits
    # clip by class (`.split-clip`), not with one.
    {"style-src-attr", ["'unsafe-inline'"]},
    {"img-src", ["'self'", "data:", "https://metadata.ens.domains"]},
    {"font-src", ["'self'"]},
    {"connect-src", ["'self'"]},
    {"frame-src", @own_frames},
    {"base-uri", ["'none'"]},
    {"form-action", ["'self'"]},
    {"frame-ancestors", ["'none'"]}
  ]

  @sign_in %{
    "script-src" => ["https://challenges.cloudflare.com"],
    "style-src" => ["'unsafe-inline'"],
    "img-src" => ["blob:", "https://explorer-api.walletconnect.com"],
    "frame-src" => [
      "https://auth.privy.io",
      "https://verify.walletconnect.com",
      "https://verify.walletconnect.org",
      "https://challenges.cloudflare.com"
    ],
    "connect-src" => [
      "https://auth.privy.io",
      "https://*.rpc.privy.systems",
      "wss://relay.walletconnect.com",
      "wss://relay.walletconnect.org",
      "https://verify.walletconnect.org",
      "https://explorer-api.walletconnect.com",
      "https://rpc.walletconnect.org",
      "https://pulse.walletconnect.org",
      "wss://www.walletlink.org"
    ]
  }

  @doc "The strict baseline, for pages that never start sign-in."
  def reading, do: render(@baseline)

  @doc """
  The baseline plus Privy wallet sign-in and the pictures of agents and Keys,
  for pages that can sign someone in.
  """
  def sign_in, do: @baseline |> add(@sign_in) |> add(pictures()) |> render()

  @doc "Sign-in plus framing its own pages, for the local showcase's preview."
  def showcase do
    @baseline
    |> add(@sign_in)
    |> add(pictures())
    |> add(%{"frame-src" => ["'self'"]})
    |> List.keyreplace("frame-ancestors", 0, {"frame-ancestors", ["'self'"]})
    |> render()
  end

  @doc """
  The baseline plus the one style element and one script element the saved-errors
  page writes inline, each admitted by this request's nonce
  (`KeyfleetWeb.ErrorsAdmin`). It never starts sign-in.
  """
  def errors(nonce) do
    nonce = "'nonce-#{nonce}'"
    @baseline |> add(%{"script-src" => [nonce], "style-src" => [nonce]}) |> render()
  end

  defp pictures,
    do: %{
      "img-src" => [Keyfleet.Agents.AvatarBucket.public_origin(), Keyfleet.Keys.KeyArt.origin()]
    }

  defp add(directives, additions) do
    Enum.map(directives, fn {directive, sources} ->
      {directive, Enum.uniq(sources ++ Map.get(additions, directive, []))}
    end)
  end

  defp render(directives) do
    directives
    |> Enum.reject(fn {_directive, sources} -> sources == [] end)
    |> Enum.map_join("; ", fn {directive, sources} -> Enum.join([directive | sources], " ") end)
  end
end
