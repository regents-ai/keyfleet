defmodule Keyfleet.Code.NodeClient do
  @moduledoc """
  What this site asks of the code store outside git itself. Every call is made
  once: the job that makes it retries the whole job.
  """

  alias Keyfleet.Code
  alias Keyfleet.Code.Pass

  @doc """
  Makes the fleet's private repository, or finds the one already made:
  `{:ok, owner}`, the owner the store keeps it under, or `{:error, reason}`.
  """
  def create_repository(fleet_id) do
    Req.post(
      [
        base_url: Code.config()[:node],
        url: "/api/v1/repos",
        auth: {:bearer, Pass.create(fleet_id)},
        json: %{name: fleet_id, is_public: false},
        retry: false,
        redirect: false,
        receive_timeout: Code.config()[:node_timeout_ms]
      ] ++ Code.config()[:req_options]
    )
    |> case do
      {:ok, %Req.Response{status: status, body: %{"owner_did" => owner}}}
      when status in [200, 201] and is_binary(owner) ->
        {:ok, owner}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:code_store_status, status}}

      {:error, error} ->
        {:error, error}
    end
  end
end
