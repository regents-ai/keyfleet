defmodule Keyfleet.TestPrivyVerifier do
  @moduledoc false

  @identity_suffix "-identity"

  @doc """
  The identity token deterministically paired with `access_token`.

  Real Privy access and identity tokens are distinct strings with distinct
  roles, so the fixtures are too. `test/browser/support/authenticated_privy.ts`
  builds the same partner for the browser suite and has to stay in step
  with this.
  """
  def identity_token(access_token), do: access_token <> @identity_suffix

  @doc """
  The session exchange the controller performs, in place of
  `RegentPrivy.Session.verify/2`.

  Only an access token names a session and only its own partner is that
  session's signed evidence, so a swapped, reused or unpaired token is no pair
  at all and never reaches the session boundary. Refusals carry the same tagged
  classification `RegentPrivy.Session.verify/2` returns.
  """
  def verify(%{access: access, identity: identity}, opts)
      when is_binary(access) and is_binary(identity) do
    access |> access_evidence() |> paired(identity == identity_token(access), opts)
  end

  # A real pair is signed just now and holds for a while, so its evidence carries
  # both times, as `RegentPrivy.Session.verify/2` gives them.
  defp paired({:ok, evidence}, true, opts) do
    now = System.system_time(:second)

    {:ok,
     struct!(
       RegentPrivy.Session,
       Map.merge(evidence, %{app_id: opts[:app_id], issued_at: now - 1, expires_at: now + 600})
     )}
  end

  defp paired({:ok, _evidence}, false, _opts), do: {:error, {:pair_binding, :session_mismatch}}
  defp paired({:error, reason}, _matched, _opts), do: {:error, {:access_verification, reason}}

  defp access_evidence("valid") do
    {:ok,
     %{
       session_id: "browser-session",
       privy_user_id: "did:privy:verified",
       wallet_address: "0x1111111111111111111111111111111111111111",
       wallet_addresses: ["0x1111111111111111111111111111111111111111"]
     }}
  end

  defp access_evidence("no-wallet") do
    {:ok,
     %{
       session_id: "browser-session",
       privy_user_id: "did:privy:verified",
       wallet_address: nil,
       wallet_addresses: []
     }}
  end

  defp access_evidence("changed-wallet") do
    {:ok,
     %{
       session_id: "browser-session",
       privy_user_id: "did:privy:verified",
       wallet_address: "0x2222222222222222222222222222222222222222",
       wallet_addresses: ["0x2222222222222222222222222222222222222222"]
     }}
  end

  defp access_evidence("other-account") do
    {:ok,
     %{
       session_id: "other-browser-session",
       privy_user_id: "did:privy:other",
       wallet_address: "0x3333333333333333333333333333333333333333",
       wallet_addresses: ["0x3333333333333333333333333333333333333333"]
     }}
  end

  defp access_evidence("conflicting-social") do
    {:ok,
     %{
       session_id: "conflicting-social-session",
       privy_user_id: "did:privy:conflicting-social",
       wallet_address: "0x5555555555555555555555555555555555555555",
       wallet_addresses: ["0x5555555555555555555555555555555555555555"],
       linked_socials: [
         %{
           provider: :x,
           subject: "shared-x-subject",
           username: "other",
           display_name: nil
         }
       ]
     }}
  end

  # The access token is well-formed for this app but its own verification is
  # refused, which is the one refusal a fresh provider login can clear. The
  # catch-all below is the generic refusal, so both live in the same stage.
  defp access_evidence("stale-access"), do: {:error, :token_verification_failed}

  defp access_evidence(_token), do: {:error, :invalid_token}
end
