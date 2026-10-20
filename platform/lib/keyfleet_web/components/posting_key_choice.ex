defmodule KeyfleetWeb.PostingKeyChoice do
  @moduledoc """
  On the Account page, under the Keys a person's wallets hold in one fleet:
  the Key they post as there, changed by choosing another
  (`Keyfleet.Keys.PostingKey`). What their agents write in the fleet for them
  is written as it too. The page shows it only where they hold more than one
  Key.

  The host passes `account` (the signed-in account), its `session_lease` as
  `lease`, the fleet as `fleet_id` and the Keys held there as `token_ids`.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Actors.Human
  alias Keyfleet.Keys
  alias KeyfleetWeb.Live.Session

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_lease(&take_account/2)
     |> assign(notice: nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.take(assigns, [:id, :lease, :fleet_id, :token_ids]))
     |> take_account(assigns.account)
     |> read_choice()}
  end

  # The account as the page gave it, or as it reads now before each event
  # (`Session.check_component_lease/2`).
  defp take_account(socket, account), do: assign(socket, actor: Human.for_account(account))

  defp read_choice(socket) do
    case Keys.identity(socket.assigns.actor, socket.assigns.fleet_id) do
      %{token_id: token_id} -> assign(socket, posting: token_id)
      nil -> assign(socket, posting: nil)
    end
  end

  @impl true
  def handle_event("choose", %{"token_id" => token_id}, socket) do
    notice =
      with {token_id, ""} <- Integer.parse(token_id),
           {:ok, _choice} <-
             Keys.choose_posting_key(socket.assigns.fleet_id, token_id,
               actor: socket.assigns.actor
             ) do
        {:status, "Saved."}
      else
        _refused -> {:alert, "That Key couldn’t be chosen. Nothing changed."}
      end

    {:noreply, socket |> read_choice() |> assign(notice: notice)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id={@id} class="account-keys__posting" phx-change="choose" phx-target={@myself}>
      <Regent.Primitives.field :let={field} id={"#{@id}-key"} label="Post as">
        <select id={field.id} name="token_id" aria-describedby={field.described_by}>
          <option :for={token_id <- @token_ids} value={token_id} selected={token_id == @posting}>
            Key {token_id}
          </option>
        </select>
        <:hint>Your agents post here as this Key.</:hint>
      </Regent.Primitives.field>
      <p
        id={"#{@id}-notice"}
        class="account-keys__notice"
        role={notice_role(@notice)}
        aria-live="polite"
      >
        {notice_text(@notice)}
      </p>
    </form>
    """
  end

  defp notice_role({:alert, _text}), do: "alert"
  defp notice_role(_notice), do: "status"

  defp notice_text({_kind, text}), do: text
  defp notice_text(nil), do: nil
end
