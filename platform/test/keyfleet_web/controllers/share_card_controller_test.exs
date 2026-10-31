defmodule KeyfleetWeb.ShareCardControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  import Keyfleet.ProposalHelpers, only: [keys_sold!: 2, treasury_reading!: 3]

  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys.KeyArt
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.{FleetProposals, ShareCard, SharePictures}
  alias Vix.Vips.{Image, Operation}

  @classic "fleet_tech_classic"
  @club "regents_club"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"
  @eth "0x0000000000000000000000000000000000000000"
  # The Interim Keyfleet Access Pass on IPFS, the picture of a Key still
  # waiting for its card.
  @pass_at "/ipfs/QmddjWKS43UPY3V1muZJGVx8zkpxCUXwmsy29heg1qNETy"

  setup do
    Fleets.bootstrap_catalog!()

    # The figures every page shares outlive a test's database, so each test
    # starts with none held.
    for fleet_id <- [@classic, @club] do
      ChainHelpers.deploy!(fleet_id)
      ChainHelpers.seed_cursor!(fleet_id)
      SharedReading.delete(ShareCard.key(fleet_id))

      on_exit(fn -> SharedReading.delete(ShareCard.key(fleet_id)) end)
    end

    # The pictures drawn, and the draws that failed, are kept by version.
    on_exit(fn -> SharePictures.delete_all() end)

    test = self()
    {:ok, card} = Image.write_to_buffer(Operation.black!(767, 959, bands: 3), ".png")

    Req.Test.stub(KeyArt, fn conn ->
      send(test, {:kept, conn.request_path})
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, card)
    end)

    :ok
  end

  test "Classic's pages name its own picture, with its Keys sold, treasury and last Key sold",
       %{conn: conn} do
    keys_sold!(@classic, [1, 2, 3])

    treasury_reading!(
      @classic,
      [
        %{asset: @eth, held: 0, backed: 0},
        %{asset: @regent, held: 2_000_999_999_999_999_999_999, backed: 0},
        %{asset: @usdc, held: 5_009_999, backed: 0}
      ],
      %{conversion_waiting: Decimal.new(113_590_000)}
    )

    FleetProposals.read(@classic)

    for path <- ["/classic/1", "/classic/1/treasury"] do
      {image, alt} = ShareCard.image(path)
      assert image =~ ~r{\Ahttps?://[^/]+/share/fleet_tech_classic\.png\?v=[0-9a-z]+\z}

      assert alt ==
               "Classic #1 on Keyfleet. Keys sold: 3 / 1,024. " <>
                 "Treasury: 118.59 USDC + 2,000 REGENT. Last Key sold: the card of CLASSIC—001—003."
    end

    response = get(conn, "/share/fleet_tech_classic.png")
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
    assert get_resp_header(response, "cache-control") == ["public, max-age=300"]
    assert size(response.resp_body) == {1200, 630}
    # Key 3 is past the one-card fixture deck and not revealed, so its
    # picture is the pass.
    assert_received {:kept, @pass_at}

    # The same figures are the same picture, kept: the card is not read again.
    assert get(conn, "/share/fleet_tech_classic.png").resp_body == response.resp_body
    refute_received {:kept, _path}

    # A sale is a new version and a new picture.
    {before, _alt} = ShareCard.image("/classic/1")
    keys_sold!(@classic, [4])
    FleetProposals.read(@classic)
    {now, alt} = ShareCard.image("/classic/1")
    assert now != before
    assert alt =~ "Keys sold: 4 / 1,024."
    assert alt =~ "CLASSIC—001—004"

    redrawn = get(conn, "/share/fleet_tech_classic.png")
    assert redrawn.resp_body != response.resp_body
    assert_received {:kept, @pass_at}
  end

  test "the Club's picture shows all its Keys and the last Key to change hands", %{conn: conn} do
    keys_sold!(@club, [5, 2])
    FleetProposals.read(@club)

    {image, alt} = ShareCard.image("/app/fleets/regents_club/workspace")
    assert image =~ "/share/regents_club.png?v="

    assert alt ==
             "Regents Club on Keyfleet. Keys: 1,998. Treasury: 0 USDC. " <>
               "Last Key to change hands: the card of REGENTS CLUB 0002."

    response = get(conn, "/share/regents_club.png")
    assert response.status == 200
    assert size(response.resp_body) == {1200, 630}
  end

  test "a Classic with no Key sold shows no card, and reads nothing to draw it", %{conn: conn} do
    FleetProposals.read(@classic)
    {_image, alt} = ShareCard.image("/classic/1")

    assert alt ==
             "Classic #1 on Keyfleet. Keys sold: 0 / 1,024. Treasury: 0 USDC. Last Key sold: no card yet."

    assert get(conn, "/share/fleet_tech_classic.png").status == 200
    refute_received {:kept, _path}
  end

  test "every other page shows the site's picture" do
    for path <- ["/", "/about", "/syndicate/1", "/classic/10", "/app/fleets/regents_clubhouse"] do
      {image, alt} = ShareCard.image(path)
      assert image =~ ~r{/images/keyfleet-share(-[0-9a-f]+)?\.png}, path
      assert alt == "agents: join, start or invest in a fleet. Three Keyfleet Key cards."
    end
  end

  test "before its figures are first read, a page names the fleet alone and its picture isn't ready",
       %{conn: conn} do
    {image, alt} = ShareCard.image("/classic/1")
    assert image =~ "/share/fleet_tech_classic.png?v="
    assert alt == "Classic #1 on Keyfleet."

    response = get(conn, "/share/fleet_tech_classic.png")
    assert response.status == 503
    assert get_resp_header(response, "retry-after") == ["60"]
    refute_received {:kept, _path}
  end

  test "a card that can't be read is a picture not ready yet", %{conn: conn} do
    keys_sold!(@classic, [1])
    FleetProposals.read(@classic)

    Req.Test.stub(KeyArt, fn conn -> Plug.Conn.send_resp(conn, 502, "") end)

    response = get(conn, "/share/fleet_tech_classic.png")
    assert response.status == 503
    assert get_resp_header(response, "retry-after") == ["60"]
  end

  test "only the fleets with a picture of their own have one", %{conn: conn} do
    for file <- ["fibonacci_cascade.png", "fleet_tech_classic.webp", "fleet_tech_classic"] do
      assert get(conn, "/share/" <> file).status == 404, file
    end
  end

  defp size(png) do
    {:ok, image} = Image.new_from_buffer(png)
    {Image.width(image), Image.height(image)}
  end
end
