defmodule KeyfleetWeb.WalletPanel do
  @moduledoc """
  One group of Keyfleet's wallet buttons: the form they read, the line naming
  what a press sends, the buttons, and every step sent from them with how it
  landed. The ash-template repository's `skills/onchain-buttons` has the
  rules; `KeyfleetWeb.OnchainSteps` holds the parts every group shares.

  The steps are built on the server by `Keyfleet.WalletSteps` for the one
  wallet that may send them: Privy's active wallet, when the signed-in account
  links it. The page receives them before anyone presses. With another wallet
  active, the figures are built for the account's own wallet, a note names
  both, and a press sends nothing and says why. Signed out, nothing is built;
  the daily split's preview, presence and the launch still show their
  figures, read from the chain the same way, without their buttons.

  Nothing here disables, hides or holds back a button while anything is
  pending: every press reaches the wallet, and the contract decides. The one
  exception is a step the chain's own state, read at the latest block, makes
  certain to fail (`figures.blocked`): `step_button/1` keeps it in view,
  disabled, with a few words saying why, and the steps are built again every
  few seconds while any is blocked, so it comes back when that state changes.

  The page renders it with `live_component`, giving:

    * `id`, `flow` (a `Keyfleet.WalletSteps` flow), `fleet` (its `fleet_id`
      and `chain_id`), `actor` (the signed-in person, or nil) and `lease`
      (the page's `session_lease`, which each of the panel's events checks
      first: `KeyfleetWeb.Live.Session.check_component_events/1`);
    * `inputs`, each field the steps read with its first value; `proposal`,
      `token_id` or `advance_id` when the flow acts on one; `refresh`, anything whose
      change means the steps are built again; `tool`, the browser tool in
      `priv/tool_manifest.json` that presses these buttons for a browser's own
      agent (`assets/js/page_tools.ts`), if any; and `class`;
    * the slots `fields`, `notes` and `buttons`, each given the panel's state
      (`inputs`, `built`, `review`, `presses`, `signer`) to read.

  Buttons name their step with `data-onchain-step` and sit outside the form;
  fields that feed the steps carry `data-onchain-input` with the name they
  are built from.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Proposals
  alias Keyfleet.WalletSteps
  alias KeyfleetWeb.Live.Session
  alias KeyfleetWeb.OnchainSteps
  alias KeyfleetWeb.WalletWords
  alias RegentChain.{Presses, Review}

  # A purchase is good for ten minutes from the block it was built at, so
  # the steps are built again well before that.
  @rebuild_buy_ms 300_000
  # How soon a group whose figures couldn't be read from the chain tries again.
  @reread_ms 10_000
  # How soon a group with a button the chain's state holds back reads it again.
  @blocked_ms 15_000
  # The groups whose figures a visitor sees, read-only.
  @shown_to_visitors [:run_split, :present, :launch_upkeep]

  @doc "Whether the steps built for the group name `step`."
  def has_step?(%{built: %{review: review}}, step), do: Review.find(review, step) != nil
  def has_step?(_panel, _step), do: false

  @doc "The figures the group's steps were built from, or an empty map before."
  def figures(%{built: %{figures: figures}}), do: figures
  def figures(_panel), do: %{}

  @doc """
  Why the chain's own state makes `step` certain to fail now, or nil. A step
  that waits on an approval is pressable as soon as the approval is sent from
  this group, before it lands: a pending transaction is never a reason.
  """
  def blocked(panel, step) do
    reason = panel |> figures() |> Map.get(:blocked, %{}) |> Map.get(step)

    if reason in [:approve_first, :approve_usdc_first] and sent?(panel, "approve"),
      do: nil,
      else: reason
  end

  attr :panel, :map, required: true, doc: "the panel's state, as its slots are given it"
  attr :step, :string, required: true
  attr :id, :string, required: true
  attr :variant, :string, default: "primary"
  slot :inner_block, required: true

  @doc """
  One wallet button: it names its step, and when the chain's own state makes
  that step certain to fail it stays in view, disabled, with why beside it.
  """
  def step_button(assigns) do
    assigns = assign(assigns, reason: blocked(assigns.panel, assigns.step))

    ~H"""
    <span class="wallet-panel-step">
      <Regent.Primitives.button
        id={@id}
        variant={@variant}
        data-onchain-step={@step}
        disabled={@reason != nil}
        aria-describedby={@reason && "#{@id}-why"}
      >
        <span data-press-label>{render_slot(@inner_block)}</span>
      </Regent.Primitives.button>
      <span :if={@reason} id={"#{@id}-why"} class="wallet-panel-why">
        {WalletWords.blocked(@reason)}
      </span>
    </span>
    """
  end

  @doc "Whether `step` has been sent and has not been turned down."
  def sent?(%{presses: presses}, step),
    do: Enum.any?(presses.sent, &(&1.name == step and &1.outcome in [:pending, :confirmed]))

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_events()
     |> OnchainSteps.init()
     |> assign(
       active: nil,
       signer: nil,
       wallet: nil,
       built: nil,
       mismatch: nil,
       inputs: %{},
       proposal: nil,
       token_id: nil,
       advance_id: nil,
       refresh: nil,
       tool: nil,
       class: nil,
       fields: [],
       notes: [],
       rebuild: nil
     )}
  end

  @impl true
  # The group's own timer: only the latest one builds the steps again.
  def update(%{rebuild: timer}, socket) do
    {:ok, if(timer == socket.assigns.rebuild, do: sync(socket), else: socket)}
  end

  def update(assigns, socket) do
    rebuild? =
      Enum.any?(
        [:actor, :fleet, :proposal, :token_id, :advance_id, :refresh],
        &(Map.get(assigns, &1) != Map.get(socket.assigns, &1))
      )

    # What was typed stays; a field the page gives later starts from the
    # value it gives.
    inputs = Map.merge(Map.get(assigns, :inputs, %{}), socket.assigns.inputs)
    socket = socket |> assign(Map.delete(assigns, :inputs)) |> assign(inputs: inputs)

    {:ok, if(rebuild?, do: sync(socket), else: socket)}
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket) do
    active = OnchainSteps.active_wallet(params)
    socket = if active == socket.assigns.active, do: socket, else: assign(socket, press_note: nil)
    {:noreply, socket |> assign(active: active) |> sync()}
  end

  def handle_event("change", params, socket),
    do: {:noreply, socket |> take_inputs(params) |> sync()}

  # A press made before its step reached the page, or before the steps caught
  # up with the form: the form is taken as the page's own, and the reply
  # carries the steps built from it, read now even where the chain is read,
  # so the press never waits on steps still being read elsewhere.
  def handle_event("prepare_and_send", %{"form" => form, "step" => step}, socket)
      when is_map(form) and is_binary(step) do
    socket = socket |> take_inputs(form) |> sync_now()

    case socket.assigns.review do
      %{} = review -> {:reply, %{review: review, send: step}, socket}
      nil -> {:reply, %{}, socket}
    end
  end

  # A proposal's words are saved as soon as the press is heard, before the
  # wallet sends the proposal, from the same form the steps are built from, so
  # the chain reader finds them when it lands. The press never waits on this,
  # and a save that fails leaves the proposal without its words on the page.
  def handle_event(
        "step_pressed",
        %{"step" => "propose", "form" => %{"text" => text}},
        %{assigns: %{flow: :propose, fleet: %{fleet_id: fleet_id}, actor: actor}} = socket
      )
      when is_binary(text) do
    Proposals.save_words(fleet_id, text, actor)
    {:noreply, socket}
  end

  def handle_event("step_pressed", _params, socket), do: {:noreply, socket}

  def handle_event("step_sent", params, socket), do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _step, reason} ->
        KeyfleetWeb.Telemetry.wallet_failed(socket.assigns.flow, reason)

        note =
          OnchainSteps.failure_note(
            reason,
            linked(socket),
            socket.assigns.active,
            chain_name(socket)
          )

        {:noreply, assign(socket, press_note: note)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  @impl true
  # A step that has landed changes what the next one needs (an approval, a
  # vote, what is waiting), so the steps are built again.
  def handle_async({:onchain_step, hash}, result, socket) do
    socket = OnchainSteps.checked(socket, hash, result)

    landed? =
      Enum.any?(
        socket.assigns.presses.sent,
        &(&1.hash == hash and &1.outcome in [:confirmed, :reverted])
      )

    {:noreply, if(landed?, do: sync(socket), else: socket)}
  end

  def handle_async(:build, {:ok, built}, socket), do: {:noreply, show(socket, built)}

  def handle_async(:build, {:exit, _reason}, socket),
    do: {:noreply, show(socket, %{review: nil, figures: %{}, problem: :unread})}

  defp take_inputs(socket, params) do
    typed =
      for {name, _first} <- socket.assigns.inputs,
          is_binary(params[name]),
          into: %{},
          do: {name, params[name]}

    assign(socket, inputs: Map.merge(socket.assigns.inputs, typed))
  end

  # The steps follow the wallet that may send them and the form. The figures
  # are built for that wallet, or for the account's own while another is
  # active; the page is given steps only for the wallet that may send them.
  defp sync(socket) do
    {socket, figures_wallet} = follow_signer(socket)
    build(socket, figures_wallet)
  end

  # As `sync/1`, but built before it returns. A build still being read lands
  # later with the same steps, and the page keeps every review a press was
  # sent from.
  defp sync_now(socket) do
    {socket, figures_wallet} = follow_signer(socket)

    if figures_wallet,
      do: show(socket, build_steps!(request(socket, figures_wallet))),
      else: build(socket, nil)
  end

  defp follow_signer(socket) do
    linked = linked(socket)
    signer = OnchainSteps.signer(linked, socket.assigns.active)

    # Signed out there is no wallet to build figures for: the flows shown to
    # visitors read theirs without one, and steps are built only for a wallet
    # the signed-in person or agent owns.
    wallet = linked && OnchainSteps.shown_wallet(linked, own_wallet(linked), socket.assigns.active)

    socket =
      socket
      |> assign(
        signer: signer,
        wallet: wallet,
        mismatch: OnchainSteps.mismatch_note(linked, socket.assigns.active)
      )
      |> drop_other_signer(signer)

    {socket, wallet}
  end

  # `Keyfleet.Actors.Human` lists the account's own wallet first.
  defp own_wallet(linked), do: List.first(linked)

  # Steps built for a wallet that may no longer send leave the page at once,
  # before new ones are read.
  defp drop_other_signer(%{assigns: %{review: %{signer: shown}}} = socket, signer)
       when shown != signer,
       do: OnchainSteps.put_review(socket, nil)

  defp drop_other_signer(socket, _signer), do: socket

  defp build(%{assigns: %{actor: nil, flow: flow}} = socket, nil)
       when flow in @shown_to_visitors do
    %{fleet: %{fleet_id: fleet_id}, token_id: token_id} = socket.assigns

    socket
    |> OnchainSteps.put_review(nil)
    |> start_async(:build, fn ->
      fleet_id
      |> WalletSteps.read_figures!(flow, %{token_id: token_id})
      |> Map.put(:review, nil)
    end)
  end

  defp build(socket, nil), do: socket |> assign(built: nil) |> OnchainSteps.put_review(nil)

  # Every group reads the chain, so its steps are built away from the page's
  # own process.
  defp build(socket, wallet) do
    request = request(socket, wallet)
    start_async(socket, :build, fn -> build_steps!(request) end)
  end

  defp request(socket, wallet) do
    %{assigns: assigns} = socket

    %{
      fleet_id: assigns.fleet.fleet_id,
      flow: assigns.flow,
      signer: wallet,
      component_id: assigns.id,
      params: %{
        inputs: assigns.inputs,
        proposal: assigns.proposal,
        token_id: assigns.token_id,
        advance_id: assigns.advance_id
      },
      actor: assigns.actor
    }
  end

  defp build_steps!(request),
    do:
      WalletSteps.build_steps!(
        request.fleet_id,
        request.flow,
        request.signer,
        request.component_id,
        request.params,
        actor: request.actor
      )

  defp show(socket, built) do
    review = if built.review && built.review.signer == socket.assigns.signer, do: built.review

    socket
    |> assign(built: built)
    |> OnchainSteps.put_review(review)
    |> rebuild_later(built)
  end

  defp rebuild_later(socket, %{problem: :unread}), do: rebuild_in(socket, @reread_ms)

  defp rebuild_later(socket, %{figures: %{blocked: blocked}}) when blocked != %{},
    do: rebuild_in(socket, @blocked_ms)

  defp rebuild_later(%{assigns: %{flow: :buy}} = socket, _built),
    do: rebuild_in(socket, @rebuild_buy_ms)

  defp rebuild_later(socket, _built), do: socket

  defp rebuild_in(socket, ms) do
    timer = make_ref()
    send_update_after(socket.assigns.myself, %{rebuild: timer}, ms)
    assign(socket, rebuild: timer)
  end

  defp linked(%{assigns: %{actor: %{wallet_addresses: wallets}}}), do: wallets
  defp linked(_socket), do: nil

  defp chain_name(%{assigns: %{fleet: %{chain_id: chain_id}}}) do
    case WalletSteps.chain(chain_id) do
      %{name: name} -> name
      nil -> "the fleet’s network"
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        panel: Map.take(assigns, [:inputs, :built, :review, :presses, :signer]),
        line: WalletWords.line(assigns.flow, assigns.built, assigns.inputs),
        chain: chain_name(%{assigns: assigns}),
        read_only: assigns.actor == nil and assigns.flow in @shown_to_visitors
      )

    ~H"""
    <section
      id={@id}
      class={["wallet-panel", @class]}
      phx-hook="OnchainSteps"
      data-webmcp-tool={@tool}
    >
      <form
        :if={@fields != []}
        id={"#{@id}-form"}
        class="wallet-panel-form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        {render_slot(@fields, @panel)}
      </form>

      {render_slot(@notes, @panel)}

      <%!-- Lines above the buttons stay in the page and are only hidden, so
           one appearing never moves the button a person is about to press. --%>
      <p id={"#{@id}-line"} class="wallet-panel-line" aria-live="polite" hidden={!@line}>
        {@line}
      </p>
      <p id={"#{@id}-from"} class="wallet-panel-note" hidden={!@wallet}>
        <%= if @wallet do %>
          Sending from <code>{RegentFormat.short_address(@wallet)}</code> on {@chain}.
        <% end %>
      </p>
      <p id={"#{@id}-mismatch"} class="wallet-panel-note" hidden={!@mismatch}>{@mismatch}</p>

      <div :if={!@read_only} class="wallet-panel-buttons">
        {render_slot(@buttons, @panel)}
      </div>

      <p :if={@press_note} id={"#{@id}-press-note"} class="wallet-panel-note" role="status">
        {@press_note}
      </p>
      <p class="wallet-panel-note" role="status" data-onchain-lost hidden>
        This page lost its connection, so nothing was sent. Press again once it's back.
      </p>

      <ol
        :if={@presses.sent != []}
        id={"#{@id}-sent"}
        class="wallet-panel-sent"
        aria-live="polite"
      >
        <li
          :for={
            {entry, shown} <-
              Enum.map(
                Presses.shown(@presses),
                &{&1, WalletWords.outcome(&1, OnchainSteps.describe(&1, @chain))}
              )
          }
          data-state={shown.state}
        >
          <strong>{WalletWords.title(entry)}</strong>
          <span>{shown.words}</span>
          <code title={entry.hash}>{RegentFormat.short_hash(entry.hash)}</code>
          <Regent.Primitives.button
            :if={shown.state == :stalled}
            variant="quiet"
            phx-click="check_again"
            phx-value-hash={entry.hash}
            phx-target={@myself}
          >
            Check again
          </Regent.Primitives.button>
        </li>
      </ol>
    </section>
    """
  end
end
