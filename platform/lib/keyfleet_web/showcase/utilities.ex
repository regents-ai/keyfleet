defmodule KeyfleetWeb.Showcase.Utilities do
  @moduledoc false

  def privy(scenario) when scenario in [:valid, :expired, :audience] do
    now = 1_750_000_000
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, public_pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()

    claims = %{
      "iss" => "privy.io",
      "aud" => if(scenario == :audience, do: "another-app", else: "showcase-fixture"),
      "sub" => "did:privy:showcase-fixture",
      "iat" => now - 10,
      "exp" => if(scenario == :expired, do: now - 1, else: now + 3600)
    }

    {_, token} = key |> JOSE.JWT.sign(%{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()

    case RegentPrivy.verify_token(token,
           app_id: "showcase-fixture",
           verification_key: public_pem,
           now: now
         ) do
      {:ok, verified} ->
        %{result: "Verified fixture", identity: verified.privy_user_id, session_created: false}

      {:error, reason} ->
        %{result: "Rejected fixture", reason: reason, session_created: false}
    end
  end
end
