defmodule KeyfleetWeb.NearFundingPanel do
  @moduledoc """
  "Fund with NEAR" on a fleet's Treasury view. A member names an amount of
  USDC and their NEAR account for refunds, sees the price, and on "Fund with
  NEAR" gets the deposit address to send NEAR to from their own wallet. The
  USDC lands at the fleet's own treasury address on Base. Anyone sees the
  fleet's fundings, each with its status and, once arrived, its receipt. A
  funding's status is read when the panel opens and on Refresh
  (`Keyfleet.Fundings`).
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Fundings
  alias Keyfleet.Fundings.Errors.{NotLive, ServiceFailed}
  alias Keyfleet.Fundings.Funding

  @usdc_unit 1_000_000

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if Map.has_key?(socket.assigns, :fundings) do
       socket
     else
       socket
       |> assign(
         member?: Keyfleet.Access.allowed?(assigns.actor, :write, :fundings, assigns.fleet_id),
         inputs: %{"amount" => "", "refund_to" => ""},
         price: nil,
         problem: nil
       )
       |> assign_fundings(connected?(socket))
     end}
  end

  @impl true
  def handle_event("edit", params, socket),
    do: {:noreply, assign(socket, inputs: inputs(params), price: nil, problem: nil)}

  def handle_event("price", params, socket) do
    inputs = inputs(params)
    socket = assign(socket, inputs: inputs)

    with {:ok, amount} <- base_units(inputs["amount"]),
         {:ok, price} <-
           Fundings.price_funding(socket.assigns.fleet_id, amount, inputs["refund_to"],
             actor: socket.assigns.actor
           ) do
      {:noreply, assign(socket, price: Map.put(price, :usdc_amount, amount), problem: nil)}
    else
      {:error, error} -> {:noreply, assign(socket, price: nil, problem: problem(error))}
    end
  end

  def handle_event("fund", _params, %{assigns: %{price: %{usdc_amount: amount}}} = socket) do
    case Fundings.start_funding(
           socket.assigns.fleet_id,
           amount,
           socket.assigns.inputs["refund_to"],
           actor: socket.assigns.actor
         ) do
      {:ok, _funding} ->
        {:noreply,
         socket
         |> assign(inputs: %{"amount" => "", "refund_to" => ""}, price: nil, problem: nil)
         |> assign_fundings(false)}

      {:error, error} ->
        {:noreply, assign(socket, problem: problem(error))}
    end
  end

  def handle_event("refresh", %{"id" => id}, socket) do
    with {:ok, %Funding{} = funding} <- Fundings.get_funding(socket.assigns.fleet_id, id),
         {:ok, _funding} <- Fundings.refresh_funding(funding, actor: socket.assigns.actor) do
      {:noreply, socket |> assign(problem: nil) |> assign_fundings(false)}
    else
      {:error, error} -> {:noreply, assign(socket, problem: problem(error))}
      {:ok, nil} -> {:noreply, assign_fundings(socket, false)}
    end
  end

  # The fleet's fundings; on opening, a member's page first reads again how
  # each one still under way stands.
  defp assign_fundings(socket, read_status?) do
    %{fleet_id: fleet_id, actor: actor, member?: member?} = socket.assigns
    fundings = Fundings.list_fundings!(fleet_id)

    if read_status? and member? and Enum.any?(fundings, &under_way?/1) do
      for funding <- fundings,
          under_way?(funding),
          do: Fundings.refresh_funding(funding, actor: actor)

      assign(socket, fundings: Fundings.list_fundings!(fleet_id))
    else
      assign(socket, fundings: fundings)
    end
  end

  defp under_way?(funding), do: funding.state not in Funding.final_states()

  defp inputs(params), do: Map.take(params, ["amount", "refund_to"])

  # Whole USDC as a person types it, such as "5" or "12.50", in base units.
  defp base_units(text) do
    with {amount, ""} <- Decimal.parse(String.trim(text || "")),
         units = Decimal.mult(amount, @usdc_unit),
         true <- Decimal.integer?(units) and Decimal.gt?(units, 0) do
      {:ok, Decimal.to_integer(units)}
    else
      _not_an_amount -> {:error, :amount}
    end
  end

  defp problem(:amount), do: "Enter an amount of USDC, up to 1,000."
  defp problem(%Ash.Error.Forbidden{}), do: "Only Key holders of this fleet can fund it here."

  defp problem(%Ash.Error.Invalid{errors: errors}) do
    Enum.find_value(errors, "That didn’t work. Check the amount and the NEAR account.", fn
      %ServiceFailed{} -> "NEAR Intents couldn’t answer just now. Try again in a moment."
      %NotLive{} -> "This fleet’s treasury opens once the fleet is live."
      %{field: :refund_to} -> "Enter a NEAR account, like alice.near."
      %{field: :usdc_amount} -> "Enter an amount of USDC, up to 1,000."
      _other -> nil
    end)
  end

  defp problem(_error), do: "That didn’t work. Try again in a moment."

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="proposals-panel near-funding" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>Funding</h2>
      <p class="proposals-detail">
        Pay in NEAR and USDC lands in this treasury on Base, swapped by NEAR Intents.
        You send NEAR from your own wallet; Keyfleet never holds or moves funds.
      </p>

      <form
        :if={@member?}
        id={"#{@id}-form"}
        class="near-funding__form"
        phx-change="edit"
        phx-submit="price"
        phx-target={@myself}
      >
        <Regent.Primitives.field :let={field} id={"#{@id}-amount"} label="USDC">
          <input
            id={field.id}
            name="amount"
            value={@inputs["amount"]}
            inputmode="decimal"
            autocomplete="off"
            placeholder="5"
          />
        </Regent.Primitives.field>
        <Regent.Primitives.field :let={field} id={"#{@id}-refund"} label="Refund account">
          <input
            id={field.id}
            name="refund_to"
            value={@inputs["refund_to"]}
            autocomplete="off"
            spellcheck="false"
            placeholder="alice.near"
          />
        </Regent.Primitives.field>
        <Regent.Primitives.button type="submit" variant="secondary" id={"#{@id}-price"}>
          Get price
        </Regent.Primitives.button>
      </form>
      <p :if={!@member?} id={"#{@id}-members"} class="proposals-detail">
        Key holders of this fleet can fund it here.
      </p>

      <Regent.Primitives.notice :if={@problem} id={"#{@id}-problem"} tone="error">
        {@problem}
      </Regent.Primitives.notice>

      <div :if={@price} id={"#{@id}-quote"} class="near-funding__quote">
        <dl class="proposals-facts">
          <div>
            <dt>You send</dt>
            <dd id={"#{@id}-quote-near"}>{near(@price.near_in_formatted)} NEAR</dd>
          </div>
          <div>
            <dt>Treasury gets</dt>
            <dd id={"#{@id}-quote-usdc"}>{usdc(@price.usdc_amount)} USDC</dd>
          </div>
          <div>
            <dt>Time</dt>
            <dd>About {@price.seconds} seconds</dd>
          </div>
          <div>
            <dt>Lands at</dt>
            <dd>
              <Regent.Primitives.address id={"#{@id}-quote-recipient"} address={@price.recipient} />
            </dd>
          </div>
        </dl>
        <Regent.Primitives.button
          id={"#{@id}-fund"}
          phx-click="fund"
          phx-target={@myself}
          phx-disable-with="Asking NEAR Intents…"
        >
          Fund with NEAR
        </Regent.Primitives.button>
      </div>

      <ol :if={@fundings != []} id={"#{@id}-list"} class="near-funding__list">
        <li
          :for={funding <- @fundings}
          id={"#{@id}-#{funding.id}"}
          data-state={funding.state}
          class="near-funding__item"
        >
          <p class="near-funding__head">
            <strong>{usdc(funding.usdc_amount)} USDC</strong>
            <Regent.Primitives.status
              id={"#{@id}-#{funding.id}-state"}
              tone={tone(funding.state)}
            >
              {words(funding.state)}
            </Regent.Primitives.status>
            <span class="proposals-detail">
              Started {Calendar.strftime(funding.inserted_at, "%-d %b, %H:%M UTC")}
            </span>
          </p>

          <div :if={funding.state in [:pending_deposit, :processing]}>
            <dl class="proposals-facts">
              <div>
                <dt>Send</dt>
                <dd id={"#{@id}-#{funding.id}-near"}>
                  {near(funding.near_in_formatted)} NEAR
                  <Regent.Primitives.copy_icon
                    id={"#{@id}-#{funding.id}-near-copy"}
                    text={funding.near_in_formatted}
                    label="Copy the amount"
                  />
                </dd>
              </div>
              <div class="near-funding__to">
                <dt>To</dt>
                <dd>
                  <code id={"#{@id}-#{funding.id}-deposit"} class="near-funding__deposit">
                    {funding.deposit_address}
                  </code>
                  <Regent.Primitives.copy_button
                    id={"#{@id}-#{funding.id}-deposit-copy"}
                    text={funding.deposit_address}
                  >
                    Copy address
                  </Regent.Primitives.copy_button>
                </dd>
              </div>
              <div :if={funding.deadline}>
                <dt>Before</dt>
                <dd>{Calendar.strftime(funding.deadline, "%-d %b, %H:%M UTC")}</dd>
              </div>
              <div>
                <dt>Refunds</dt>
                <dd>{funding.refund_to}</dd>
              </div>
            </dl>
            <p class="proposals-detail">
              Copy the exact amount and send it from your own NEAR wallet, on the NEAR network,
              before the deadline. If the swap can’t finish, NEAR Intents refunds it to {funding.refund_to}.
            </p>
          </div>

          <dl
            :if={funding.state == :success}
            id={"#{@id}-#{funding.id}-receipt"}
            class="proposals-facts near-funding__receipt"
          >
            <div>
              <dt>Amount</dt>
              <dd>{usdc(funding.usdc_amount)} USDC</dd>
            </div>
            <div>
              <dt>Landed at</dt>
              <dd>
                <Regent.Primitives.address
                  id={"#{@id}-#{funding.id}-recipient"}
                  address={funding.recipient}
                />
              </dd>
            </div>
            <div :if={funding.origin_tx}>
              <dt>NEAR</dt>
              <dd>
                <a
                  id={"#{@id}-#{funding.id}-origin"}
                  href={"https://nearblocks.io/txns/#{funding.origin_tx}"}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  {short(funding.origin_tx)}
                </a>
              </dd>
            </div>
            <div :if={funding.destination_tx}>
              <dt>Base</dt>
              <dd>
                <Regent.Primitives.address
                  id={"#{@id}-#{funding.id}-destination"}
                  address={funding.destination_tx}
                  kind="tx"
                />
              </dd>
            </div>
            <div :if={funding.finished_at}>
              <dt>Time</dt>
              <dd>{Calendar.strftime(funding.finished_at, "%-d %b %Y, %H:%M UTC")}</dd>
            </div>
            <div>
              <dt>Signature</dt>
              <dd>Not checked</dd>
            </div>
          </dl>

          <p :if={funding.state == :refunded} class="proposals-detail">
            NEAR Intents refunded the NEAR to {funding.refund_to}.
          </p>
          <p :if={funding.state == :failed} class="proposals-detail">
            The swap failed. Nothing reached the treasury.
          </p>

          <Regent.Primitives.button
            :if={@member? and funding.state in [:pending_deposit, :processing]}
            id={"#{@id}-#{funding.id}-refresh"}
            variant="secondary"
            arrow={false}
            phx-click="refresh"
            phx-value-id={funding.id}
            phx-target={@myself}
          >
            Refresh
          </Regent.Primitives.button>
        </li>
      </ol>
    </section>
    """
  end

  defp usdc(units),
    do: units |> Decimal.div(@usdc_unit) |> Decimal.normalize() |> Decimal.to_string(:normal)

  # NEAR as a person reads it: four decimals at most, rounded up so the figure
  # read is never short of the amount the copy button gives exactly.
  defp near(formatted),
    do:
      formatted
      |> Decimal.new()
      |> Decimal.round(4, :ceiling)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

  defp short(hash) when byte_size(hash) > 14,
    do: binary_part(hash, 0, 6) <> "…" <> binary_part(hash, byte_size(hash) - 6, 6)

  defp short(hash), do: hash

  defp words(:pending_deposit), do: "Waiting"
  defp words(:processing), do: "Processing"
  defp words(:success), do: "Arrived"
  defp words(:refunded), do: "Refunded"
  defp words(:failed), do: "Failed"

  defp tone(:success), do: "success"
  defp tone(:refunded), do: "warning"
  defp tone(:failed), do: "error"
  defp tone(_under_way), do: "info"
end
