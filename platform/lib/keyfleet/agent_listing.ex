defmodule Keyfleet.AgentListing do
  @moduledoc """
  What the SIWA sign-in server says about an agent's wallet beyond signing in:
  its page in the agent registry, if it listed itself there, and whether a
  World ID-verified person stands behind it in World's AgentBook.

  Nothing is kept here. A page that shows one agent reads it live (`read/1`),
  and a signed request carries it in the sign-in server's answer
  (`from_sign_in/2`). The person behind an agent is not named.
  """

  @type t :: %{registry_url: String.t() | nil, human_backed?: boolean()}

  @doc "Reads the wallet's listing from the sign-in server."
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(wallet_address) do
    config = Application.fetch_env!(:keyfleet, __MODULE__)

    # The lookup also answers the wallet's requests since `since`; asking from
    # now leaves that empty.
    Req.post(
      [
        base_url: Application.fetch_env!(:keyfleet, :siwa_broker_url),
        url: "/api/shared/siwa/activity",
        auth: {:bearer, config[:read_token]},
        json: %{wallet_address: wallet_address, since: DateTime.to_iso8601(DateTime.utc_now())},
        retry: false,
        redirect: false,
        connect_options: [timeout: 2_000],
        receive_timeout: 3_000
      ] ++ config[:req_options]
    )
    |> case do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"agentRegistration" => registration, "agentBook" => book}}
       }} ->
        {:ok, from_sign_in(registration, book)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:sign_in_server_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "The listing from the sign-in server's `agentRegistration` and `agentBook`."
  @spec from_sign_in(map() | nil, map() | nil) :: t()
  def from_sign_in(registration, book),
    do: %{registry_url: registry_url(registration), human_backed?: human_backed?(book)}

  defp registry_url(nil), do: nil
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: url

  defp human_backed?(nil), do: false
  defp human_backed?(%{"humanId" => "0x" <> _rest}), do: true
end
