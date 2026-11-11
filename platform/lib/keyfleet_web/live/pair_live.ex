defmodule KeyfleetWeb.PairLive do
  @moduledoc """
  Pair New Agent as a page of its own: `/pair?to=<path>`, where `to` is a page
  on this site, as a project's "Bring your agent" links open it. A person pairs
  their agent in the same pairing box as the pairing window's
  (`KeyfleetWeb.PairingBox`), and the message they paste sends the agent to that
  page once it is paired. A link with no `to`, or one that is not
  a page on this site, opens plain pairing.
  """
  use KeyfleetWeb, :html
  import KeyfleetWeb.Components.PageHead, only: [page_head: 1]

  # A page on this site: one leading "/", never "//" or "/\", which browsers read
  # as another site, and no spaces or control characters.
  @page ~r|\A/(?![/\\])[^\s\\\x00-\x1f\x7f]{0,511}\z|u

  @doc "The page a pairing link names, or nil when it names none on this site."
  @spec start(map()) :: String.t() | nil
  def start(%{"to" => to}) when is_binary(to), do: if(to =~ @page, do: to)
  def start(_params), do: nil

  attr :account, :map, default: nil
  attr :lease, :any, required: true
  attr :start, :string, default: nil
  attr :signed_out_reason, :atom, required: true

  def page(assigns) do
    ~H"""
    <article id="pair-page" class="account-page pair-page">
      <.page_head title="Pair New Agent" />
      <p :if={@start} id="pair-start">
        Once paired, it starts at <a href={@start}>{KeyfleetWeb.Endpoint.url() <> @start}</a>
      </p>
      <Regent.Account.signed_out
        :if={is_nil(@account)}
        id="pair-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <.live_component
        :if={@account}
        module={KeyfleetWeb.PairingBox}
        id="pair-pairing-box"
        lease={@lease}
        account={@account}
        start={@start}
      />
    </article>
    """
  end
end
