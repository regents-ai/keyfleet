defmodule KeyfleetWeb.RedTeamHelpers do
  @moduledoc """
  Shared setup for the authorized security red-team regression probes
  (`test/keyfleet_web/security/`). Each probe performs a concrete attack and
  asserts the safe outcome, so flipping a protection off locally makes the
  probe fail — the "attack succeeds with the guard off, is refused with it on"
  proof the security pass records.

  It reuses the signed-request machinery the contract test proves
  (`KeyfleetWeb.SignedAgentHelpers`), a deployed test fleet, and the pairing
  and chain fixtures, so a probe only has to describe the attack.
  """
  import ExUnit.Assertions

  alias Keyfleet.{Actors, ChainHelpers, ChainViews, Fleets, Keys, PairingHelpers, Rooms}
  alias KeyfleetWeb.SignedAgentHelpers

  @fleet "fibonacci_syndicate"

  @doc "The deployed test fleet every probe acts in."
  def fleet, do: @fleet

  @doc """
  Boots a product server with the catalog, a deployed fleet, its rooms, the
  shared chain view, the local sign-in broker and a product app. Returns
  `%{app: url, secret: secret, fleet: id}` for `send_signed/5`.
  """
  def start_app! do
    # A shared sandbox owner so the in-process product server's request
    # processes see the test's data (the contract test does the same).
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    ChainViews.share!()

    budget = Application.fetch_env!(:keyfleet, :api_rate_limit)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:keyfleet, :api_rate_limit, budget) end)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    app =
      SignedAgentHelpers.serve!(
        :product,
        &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2))
      )

    %{app: app, secret: secret, fleet: @fleet}
  end

  @doc "A fresh signing wallet whose agent is paired with a person of its own."
  def paired_signer! do
    signer = unpaired_signer!()
    PairingHelpers.pair_wallet!(signer.address)
    signer
  end

  @doc "A fresh signing wallet with no pairing: a stranger."
  def unpaired_signer! do
    {:ok, signer} = Siwa.LocalSigner.new()
    signer
  end

  @doc "Records `wallet` as the current owner of `token_id` in the test fleet."
  def record_owner!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  @doc """
  Signs `method path` with `signer` under the app's broker secret and sends it
  to the product app over HTTP, the way a real agent would. `body` is a map or
  `nil` for a read. Returns the `Req.Response`.
  """
  def send_signed(ctx, signer, method, path, body \\ nil) do
    request =
      SignedAgentHelpers.sign(
        signer,
        ctx.secret,
        Siwa.Contract.authority(ctx.app),
        method,
        path,
        body && Jason.encode!(body)
      )

    Req.request!(
      method: verb(method),
      url: ctx.app <> request.path,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false
    )
  end

  @doc "The refusal code a response carries, or `nil` for a non-refusal body."
  def refusal_code(%Req.Response{body: %{"error" => %{"code" => code}}}), do: code
  def refusal_code(_response), do: nil

  @doc "Asserts a response is a refusal with `status` and `code`."
  def assert_refused(%Req.Response{} = response, status, code) do
    assert response.status == status,
           "expected #{status} #{code}, got #{response.status}: #{inspect(response.body)}"

    assert refusal_code(response) == code,
           "expected code #{code}, got #{inspect(response.body)}"

    response
  end

  defp verb(method), do: method |> String.downcase() |> String.to_existing_atom()
end
