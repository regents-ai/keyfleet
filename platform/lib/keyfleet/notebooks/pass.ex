defmodule Keyfleet.Notebooks.Pass do
  @moduledoc """
  The pass every request to a fleet's hub carries: an ES256 JWT this site
  signs, naming who the request is for (`sub`, `email`) and which fleet's hub
  may accept it (`aud` is `keyfleet-hub:<fleet id>`). It lasts
  `pass_ttl_seconds`.

  The keys are the JWK Set in `config :keyfleet, :notebooks, signing_keys`
  (`KEYFLEET_HUB_SIGNING_KEY`). The first signs; every one is published at
  `/.well-known/hub-jwks.json`, so a new key can be published before it signs
  and an old one kept until the passes it signed have run out. Each key is
  named by its RFC 7638 thumbprint.
  """

  alias Keyfleet.Notebooks

  @doc "A pass for `subject` to the fleet's hub."
  def mint(fleet_id, subject) do
    [signer | _published] = keys()
    now = System.system_time(:second)

    claims = %{
      "iss" => Notebooks.config()[:issuer],
      "aud" => audience(fleet_id),
      "sub" => subject,
      "email" => Notebooks.email(subject),
      "iat" => now,
      "exp" => now + Notebooks.config()[:pass_ttl_seconds]
    }

    {_fields, token} =
      signer
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => kid(signer), "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  @doc "Who a pass for the fleet's hub is for."
  def audience(fleet_id), do: "keyfleet-hub:#{fleet_id}"

  @doc "The public half of every key, as the JWK Set the hubs read."
  def jwks do
    %{
      "keys" =>
        Enum.map(keys(), fn key ->
          {_fields, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
          Map.merge(public, %{"kid" => kid(key), "alg" => "ES256", "use" => "sig"})
        end)
    }
  end

  defp keys do
    case Notebooks.config()[:signing_keys] do
      nil -> []
      set -> set |> Jason.decode!() |> Map.fetch!("keys") |> Enum.map(&JOSE.JWK.from_map/1)
    end
  end

  defp kid(key), do: JOSE.JWK.thumbprint(key)
end
