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

  # Only a partitioned test database on the loopback address, judged by the name
  # the repo is configured with: `keyfleet_<partition>_test`, as a non-empty
  # MIX_TEST_PARTITION gives it. The shared unpartitioned `keyfleet_test`, a URL
  # and any other host are refused.
  @partitioned_test_database ~r/\Akeyfleet_[a-z0-9]+(?:_[a-z0-9]+)*_test\z/

  def database do
    config = Keyfleet.Repo.config()

    if is_nil(config[:url]) and config[:hostname] in ["127.0.0.1", "localhost"] and
         Regex.match?(@partitioned_test_database, config[:database] || "") do
      case Ecto.Adapters.SQL.query(Keyfleet.Repo, "SELECT current_database(), 1", [],
             timeout: 2_000
           ) do
        {:ok, %{rows: [[name, 1]]}} -> %{database: name, result: "SELECT 1 passed", writes: 0}
        {:error, _} -> %{error: "Local database unavailable."}
      end
    else
      %{error: "This diagnostic requires a prepared isolated local test database."}
    end
  catch
    :exit, _ -> %{error: "Local database process unavailable."}
  end
end
