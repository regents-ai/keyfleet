defmodule KeyfleetWeb.Security.OutsideDepsPropertyTest do
  @moduledoc """
  The invariants behind the outside-dependency probes
  (`KeyfleetWeb.Security.OutsideDepsTest`), checked over generated requests
  and races rather than one example each, against the shared libraries' real
  code at the ref `mix.lock` pins:

    * a SIWA signature verifies for the one method, path, body and wallet it
      was signed for, once, and every single change to any of them is refused
      for that change's own reason;
    * however Credits holds race, the Credits held are exactly the placed
      holds, nothing is spent twice, and a hold is refused only when it no
      longer fits.

  The probes prove the site hands the sign-in server the request as it
  arrived; these prove what the sign-in server's checks then guarantee.
  The `Host` is not among what a signature covers
  (`docs/security/outside-dependencies-2026-10-18.md`), so nothing here
  changes it.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias KeyfleetWeb.SignedAgentHelpers
  alias RegentCredits.Actor
  alias RegentCredits.Errors.NotEnoughCredits

  @moduletag :capture_log

  @methods ~w(GET POST PUT PATCH DELETE)
  @verify [audience: "keyfleet", wallet_audiences: ["keyfleet"]]
  @authority "keyfleet.ai"

  describe "a SIWA signature binds its request (OD-SIWA-BINDING)" do
    setup do
      {:ok, signer} = Siwa.LocalSigner.new()
      {:ok, signer: signer, secret: :crypto.strong_rand_bytes(32)}
    end

    property "OD-SIWA-BINDING: a signed request verifies once as signed, and any one change is refused",
             c do
      check all method <- member_of(@methods),
                path <- path(),
                body <- body(),
                change <- change(method, path, body),
                max_runs: 200 do
        signed = SignedAgentHelpers.sign(c.signer, c.secret, @authority, method, path, body)
        changed = apply_change(signed, change)

        assert verify(changed, c.secret) == {:error, refusal(change, body)}

        assert {:ok, %{address: address}} = verify(signed, c.secret)
        assert String.downcase(address) == String.downcase(c.signer.address)
        assert verify(signed, c.secret) == {:error, :replayed_request}
      end
    end
  end

  describe "Credits holds racing on separate connections (OD-CREDITS-PROPERTY)" do
    # As in OD-CREDITS-LOCK: each caller has its own connection, so the holds
    # really wait on each other's row lock, and their rows stay committed in
    # the test database under people no other test names.
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :manual) end)

      admin = "did:privy:outside-deps-admin"
      admins = Application.get_env(:regent_credits, :admins)
      Application.put_env(:regent_credits, :admins, [admin])
      on_exit(fn -> Application.put_env(:regent_credits, :admins, admins) end)
      {:ok, admin: admin}
    end

    @tag :external
    property "OD-CREDITS-PROPERTY: racing holds place each key once and hold exactly what they placed",
             c do
      # Up to eight callers, each holding one of four keys; a key always asks
      # for the same amount, as a retried request does.
      check all funded <- integer(1..6),
                keys <- list_of(integer(0..3), min_length: 2, max_length: 8),
                max_runs: 25 do
        person = fund!(c.admin, funded)

        results =
          keys
          |> Task.async_stream(&hold(person, &1), max_concurrency: 8, timeout: 30_000)
          |> Enum.map(fn {:ok, result} -> result end)

        by_key = keys |> Enum.zip(results) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        placed =
          for {key, answers} <- by_key, Enum.any?(answers, &match?({:ok, _}, &1)) do
            # A key placed once is answered with that same hold every time.
            assert Enum.all?(answers, &match?({:ok, _}, &1)), inspect(answers)

            assert answers |> Enum.map(fn {:ok, hold} -> hold.id end) |> Enum.uniq() |> length() ==
                     1

            key
          end

        held = placed |> Enum.map(&amount/1) |> Enum.sum()
        available = funded - held
        balance = RegentCredits.balance(person)

        assert Decimal.eq?(balance.held, held), inspect(balance)
        assert Decimal.eq?(balance.available, available), inspect(balance)
        refute Enum.any?([balance.given, balance.purchased, balance.held], &Decimal.negative?/1)

        # A refused hold asked for more than was left, even at the end.
        for {key, answers} <- by_key, key not in placed do
          assert Enum.all?(answers, &not_enough?/1), inspect(answers)
          assert amount(key) > available
        end
      end
    end
  end

  # -- SIWA --

  defp path do
    segment = string([?a..?z, ?0..?9, ?_, ?-], min_length: 1, max_length: 12)
    map(list_of(segment, min_length: 1, max_length: 5), &("/api/v1/agent/" <> Enum.join(&1, "/")))
  end

  defp body, do: one_of([constant(nil), string(:printable, max_length: 200)])

  defp change(method, path, body) do
    one_of([
      map(filter(member_of(@methods), &(&1 != method)), &{:method, &1}),
      map(filter(path(), &(&1 != path)), &{:path, &1}),
      map(filter(body(), &(&1 != body)), &{:body, &1}),
      map(binary(length: 20), &{:wallet, "0x" <> Base.encode16(&1, case: :lower)}),
      constant(:signer)
    ])
  end

  defp apply_change(request, {:method, method}), do: %{request | method: method}
  defp apply_change(request, {:path, path}), do: %{request | path: path}
  defp apply_change(request, {:body, body}), do: %{request | body: body}

  defp apply_change(request, {:wallet, wallet}),
    do: put_in(request.headers["x-agent-wallet-address"], wallet)

  # Another wallet signs the same message under the first wallet's receipt.
  defp apply_change(request, :signer) do
    {:ok, other} = Siwa.LocalSigner.new()
    {:ok, message} = Siwa.RequestAuth.signing_message(request)
    {:ok, "0x" <> hex} = Siwa.LocalSigner.sign_message(other, message)
    encoded = hex |> Base.decode16!(case: :mixed) |> Base.encode64()
    signature = "#{Siwa.Contract.label()}=:#{encoded}:"
    put_in(request.headers[Siwa.Contract.signature_header()], signature)
  end

  # A signature over another method or path, or by another wallet, recovers
  # an address that isn't the receipt's wallet. The library then asks the
  # chain whether that wallet is a smart wallet that accepts it, and with no
  # chain to ask here the lookup fails; either way the request is refused.
  defp refusal({field, _}, _body) when field in [:method, :path], do: :signature_lookup_failed
  defp refusal(:signer, _body), do: :signature_lookup_failed
  defp refusal({:wallet, _}, _body), do: :receipt_binding_mismatch
  defp refusal({:body, nil}, _signed), do: :request_body_required
  defp refusal({:body, _body}, nil), do: :missing_signed_headers
  defp refusal({:body, _body}, _signed), do: :content_digest_mismatch

  # The request as the site hands it to the sign-in server: its headers and
  # the digest of the body that arrived.
  defp verify(request, secret) do
    Siwa.verify_authenticated_request(
      %{
        method: request.method,
        path: request.path,
        authority: request.authority,
        headers: request.headers,
        body_digest: Siwa.RequestAuth.content_digest_for_body(request.body)
      },
      [secret: secret, authorities: [@authority]] ++ @verify
    )
  end

  # -- Credits --

  defp amount(key), do: rem(key, 3) + 1

  defp fund!(admin, amount) do
    person = "did:privy:outside-deps-" <> Ecto.UUID.generate()

    {:ok, [_gift]} =
      RegentCredits.give("outside-deps-#{Ecto.UUID.generate()}", [person], Decimal.new(amount),
        actor: Actor.admin(admin)
      )

    person
  end

  defp hold(person, key) do
    RegentCredits.hold("property-#{key}-#{person}", person, Decimal.new(amount(key)), "probe",
      actor: Actor.person(person, [], "keyfleet")
    )
  end

  defp not_enough?({:error, %Ash.Error.Invalid{errors: [%NotEnoughCredits{} | _]}}), do: true
  defp not_enough?(_result), do: false
end
