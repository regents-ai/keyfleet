defmodule Keyfleet.OAuth do
  @moduledoc """
  Consent for connected apps, such as a Claude connector, through the person's
  verified Keyfleet account. The one permission lets the app keep a Regents
  identity, pair it with this account and check it in; nothing else.
  """
  @behaviour RegentOAuth

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.VerifiedSession

  def config, do: Application.fetch_env!(:keyfleet, __MODULE__)
  def repo, do: Keyfleet.Repo

  @doc """
  Whether the Claude connector is switched on (`KEYFLEET_CLAUDE_CONNECTOR_ENABLED`):
  its sign-in, its MCP address and its guide all follow this one setting.
  """
  def enabled?, do: Keyword.fetch!(config(), :enabled?)

  def current_subject(conn) do
    case conn.assigns[:current_human_account] do
      %{privy_user_id: subject} = account ->
        if VerifiedSession.current?(account), do: subject

      _ ->
        nil
    end
  end

  # An account that can't be read now counts as not active, so the app is
  # asked to connect again rather than shown a server error.
  def active_subject?(subject) do
    case Accounts.get_by_privy_did(subject, actor: %Keyfleet.Actors.System{}) do
      {:ok, account} -> VerifiedSession.current?(account)
      {:error, _error} -> false
    end
  end
end
