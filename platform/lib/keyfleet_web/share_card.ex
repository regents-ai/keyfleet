defmodule KeyfleetWeb.ShareCard do
  @moduledoc """
  The picture a link to a page shows where it is shared, such as on X.

  Classic #1's and the Regents Club's pages, and every page under them, show
  their fleet's own: its name, how many Keys it has, what its treasury holds
  and the card of its latest Key, drawn from its figures as the picture is
  asked for. A project's page in either fleet shows the project's own
  instead: its fleet's name, its title, and the name and card of the Key
  holding it, the line under its title asking an agent in. Every other page
  shows the site's picture.

  Each fleet's projects, as their pictures show them, are read with its
  Treasury page too and held beside its figures (`project_key/1`). A project
  the last read did not find, or one made since, shows its fleet's picture
  until the next read, within a minute. A title with a character the
  picture's set has not got is set as the project's name, its hyphens as
  spaces.

  Each fleet's figures are read with its Treasury page by
  `KeyfleetWeb.FleetProposals` and held in `Keyfleet.SharedReading`, so a
  page naming its picture and the picture itself read nothing from the
  database, and a page whose fleet can't be read still shows. Before its
  figures are first read, a page names the picture with the fleet's name
  alone and the picture is not ready yet.

  Each fleet's picture without its figures, the characters its figures are
  set in and where they go are drawn by `scripts/share-cards/render.mjs` into
  `priv/share`. A page names its fleet's picture with a version of its
  figures, so a site that keeps pictures by their address, as X does, asks
  again once they change. The last picture drawn of each fleet is kept in
  `:persistent_term` with its figures, so it is drawn again only when they
  change.

  A fleet's treasury is what its treasury holds of USDC, REGENT and ETH,
  with the USDC from Key sales still waiting to turn into REGENT; another
  token is left out, since its own name for itself is not to be trusted.
  """

  use KeyfleetWeb, :verified_routes

  alias Keyfleet.{Chain, Fleets, Keys, Projects, SharedReading, Treasury}
  alias Keyfleet.Fleets.{Presets, Rules}
  alias Keyfleet.Keys.{KeyArt, Metadata}
  alias KeyfleetWeb.{DirectoryMD, ProposalsPage}
  alias Vix.Vips.{Image, Operation}

  @layout_path Path.join([__DIR__, "..", "..", "priv", "share", "layout.json"])
  @external_resource @layout_path
  @layout @layout_path |> File.read!() |> Jason.decode!()
  @slots @layout["slots"]
  @project_slots @layout["project_slots"]
  @glyphs @layout["glyphs"]
  @labels @layout["fleets"]

  @site_alt "agents: join, start or invest in a fleet. Three Keyfleet Key cards."

  @doc """
  The picture the page at `path` shows where it is shared, as `{address,
  alt}`: a project's own for its page in a fleet with a picture of its own,
  its fleet's for the fleet's other pages, the site's for any other.
  """
  def image(path) do
    case project_page(path) do
      {fleet_id, name, project} ->
        address = url(~p"/share/projects/#{fleet_id}/#{name <> ".png"}?#{[v: version(project)]}")
        {address, project_alt(fleet_id, project)}

      nil ->
        fleet_image(path)
    end
  end

  defp fleet_image(path) do
    case Enum.find(fleets(), &fleet_page?(path, &1)) do
      nil ->
        {static(), @site_alt}

      fleet_id ->
        figures = held(fleet_id)
        address = url(~p"/share/#{fleet_id <> ".png"}?#{[v: version(figures)]}")
        {address, alt(fleet_id, figures)}
    end
  end

  defp static, do: url(~p"/images/keyfleet-share.png")

  defp fleet_page?(path, fleet_id) do
    under = Fleets.path(fleet_id)
    path == under or String.starts_with?(path, under <> "/")
  end

  @doc "The fleets with a picture of their own."
  def fleets, do: Map.keys(@labels)

  @doc "Where the figures on `fleet_id`'s picture are held."
  def key(fleet_id), do: {:share_card, fleet_id}

  @doc "Where what the pictures of `fleet_id`'s projects show is held."
  def project_key(fleet_id), do: {:project_cards, fleet_id}

  # The project whose page is at `path`, in a fleet with a picture of its
  # own, as `{fleet_id, name, project}`, or nil for any other page and for a
  # project its fleet's last read did not find.
  defp project_page(path) do
    Enum.find_value(fleets(), fn fleet_id ->
      prefix = Fleets.path(fleet_id) <> "/projects/"

      with true <- String.starts_with?(path, prefix),
           name = String.replace_prefix(path, prefix, ""),
           %{} = project <- Map.get(projects(fleet_id), name) do
        {fleet_id, name, project}
      else
        _other -> nil
      end
    end)
  end

  # What the last read of `fleet_id`'s projects found, by name.
  defp projects(fleet_id) do
    case SharedReading.fetch(project_key(fleet_id)) do
      {:ok, %{reading: %{} = projects}} -> projects
      _not_read -> %{}
    end
  end

  @doc """
  The picture of `fleet_id`, a PNG of 1200 by 630, as `{:ok, png}`, or
  `{:error, reason}` before its figures are first read or when its latest
  Key's card can't be read.
  """
  def png(fleet_id) do
    case held(fleet_id) do
      nil -> {:error, :not_read}
      figures -> kept({__MODULE__, fleet_id}, version(figures), fn -> draw(fleet_id, figures) end)
    end
  end

  @doc """
  The picture of the project `name` of `fleet_id`, a PNG of 1200 by 630, as
  `{:ok, png}`, or `{:error, reason}` when its fleet's last read of its
  projects did not find it or its Key's card can't be read.
  """
  def project_png(fleet_id, name) do
    case Map.get(projects(fleet_id), name) do
      nil ->
        {:error, :not_read}

      project ->
        kept({__MODULE__, fleet_id, name}, version(project), fn ->
          draw_project(fleet_id, project)
        end)
    end
  end

  # The picture last drawn at `place`, if it was drawn from the same version
  # of what it shows; else drawn again and kept.
  defp kept(place, version, draw) do
    case :persistent_term.get(place, nil) do
      {^version, png} ->
        {:ok, png}

      _other ->
        with {:ok, png} <- draw.() do
          :persistent_term.put(place, {version, png})
          {:ok, png}
        end
    end
  end

  # The figures last read, whether or not the read after them failed.
  defp held(fleet_id) do
    case SharedReading.fetch(key(fleet_id)) do
      {:ok, %{reading: %{} = figures}} -> figures
      _not_read -> nil
    end
  end

  @doc """
  What `fleet_id`'s picture shows: its Keys and treasury as set on it, and
  its latest Key's name and card picture, nil before it has one. Read by
  `KeyfleetWeb.FleetProposals`, which holds them.
  """
  def figures(fleet_id) do
    fleet = Fleets.get_fleet!(fleet_id)
    sold = minted!(fleet_id)
    token_id = latest(fleet_id, sold)

    %{
      keys: keys(fleet_id, sold),
      treasury: treasury(fleet, Treasury.get_reading!(fleet_id)),
      name: token_id && Fleets.key_name(fleet_id, token_id),
      cid: token_id && Metadata.image_cid(fleet, token_id)
    }
  end

  @doc """
  What the pictures of `fleet_id`'s projects show, by project name: each
  title as its page shows it, set in the characters the picture has, and the
  name and card picture of the Key holding it, both nil for a project no Key
  holds. Every project its page shows is here, an archived one too. Read by
  `KeyfleetWeb.FleetProposals`, which holds them.
  """
  def project_figures(fleet_id) do
    fleet = Fleets.get_fleet!(fleet_id)
    projects = Projects.project_titles!(fleet_id)

    holders = for %{key: key} <- projects, is_integer(key), uniq: true, do: key

    cards =
      holders
      |> Enum.chunk_every(100)
      |> Enum.reduce(%{}, &Map.merge(&2, Metadata.card_cids(fleet, &1)))

    Map.new(projects, fn project ->
      {project.name,
       %{
         title: title(project),
         key: project.key && Fleets.key_name(fleet_id, project.key),
         cid: project.key && Map.get(cards, project.key, Metadata.pass_cid())
       }}
    end)
  end

  # The project's title as its page shows it, if the picture has every one of
  # its characters; else its name, its hyphens as spaces.
  defp title(project) do
    shown = project.title |> DirectoryMD.visible() |> String.trim()
    characters = @glyphs["title"]["characters"]

    if shown != "" and Enum.all?(String.graphemes(shown), &Map.has_key?(characters, &1)),
      do: shown,
      else: project.name |> String.replace("-", " ") |> String.capitalize()
  end

  defp minted!(fleet_id) do
    case Chain.minted(fleet_id) do
      {:ok, minted} -> minted
      {:error, failure} -> raise failure
    end
  end

  defp version(figures),
    do: figures |> :erlang.phash2() |> Integer.to_string(36) |> String.downcase()

  # A fleet whose Keys are given has all of them from the start, and its
  # latest is the one to change hands last; any other's latest is the last
  # sold, its highest number.
  defp keys(fleet_id, sold) do
    total = Rules.grouped(Presets.max_supply(fleet_id))
    if Presets.given?(fleet_id), do: total, else: "#{Rules.grouped(sold)} / #{total}"
  end

  defp latest(fleet_id, sold) do
    if Presets.given?(fleet_id) do
      case Keys.newest_key_change!(fleet_id) do
        nil -> nil
        change -> change.token_id
      end
    else
      if sold > 0, do: sold
    end
  end

  # Each asset to the places worth showing, rounded down so a picture never
  # shows more than is there: USDC to the cent, REGENT whole, ETH to four
  # places, one to a line. A treasury not read yet holds nothing yet, as it
  # does when its fleet opens.
  defp treasury(_fleet, nil), do: ["0 USDC"]

  defp treasury(fleet, reading) do
    held = Map.new(reading.assets, &{&1.asset, &1.held})
    waiting = Decimal.to_integer(reading.conversion_waiting)

    [
      {Map.get(held, fleet.usdc_address, 0) + waiting, 6, 2, "USDC"},
      {Map.get(held, fleet.regent_address, 0), 18, 0, "REGENT"},
      {Map.get(held, Treasury.native(), 0), 18, 4, "ETH"}
    ]
    |> Enum.map(fn {atoms, decimals, shown, symbol} ->
      {div(atoms, Integer.pow(10, decimals - shown)), shown, symbol}
    end)
    |> Enum.reject(fn {amount, _shown, _symbol} -> amount == 0 end)
    |> case do
      [] ->
        ["0 USDC"]

      amounts ->
        Enum.map(amounts, fn {a, shown, s} -> "#{ProposalsPage.units(a, shown)} #{s}" end)
    end
  end

  defp alt(fleet_id, nil), do: "#{@labels[fleet_id]["name"]} on Keyfleet."

  defp alt(fleet_id, figures) do
    %{"name" => name, "keys" => keys, "key" => key} = @labels[fleet_id]
    card = if figures.name, do: "the card of #{figures.name}", else: "no card yet"

    "#{name} on Keyfleet. #{keys}: #{figures.keys}. Treasury: #{Enum.join(figures.treasury, " + ")}. " <>
      "#{key}: #{card}."
  end

  defp project_alt(fleet_id, project) do
    held = if project.key, do: "Held by #{project.key}", else: "Shared by every Key"
    "#{project.title}, a project of #{Fleets.name(fleet_id)} on Keyfleet. #{held}."
  end

  defp draw_project(fleet_id, project) do
    title = @project_slots["title"]

    with {:ok, card} <- card(project.cid) do
      ("project_" <> fleet_id <> ".png")
      |> share_file()
      |> opaque()
      |> set_lines(wrap(project.title, "title", title), "title", title)
      |> set(project.key || "EVERY KEY", "name", @project_slots["name"], :centre)
      |> place(card, @project_slots["picture"])
      |> Operation.flatten!()
      |> Image.write_to_buffer(".png")
    end
  end

  # `text` broken between words into lines no wider than `slot`, in `style`,
  # as many as the slot has room for: the last takes the words left over, and
  # `set/5` makes it smaller to fit.
  defp wrap(text, style, slot) do
    room = div(slot["height"], @glyphs[style]["height"])
    [first | rest] = String.split(text, " ", trim: true)

    lines =
      rest
      |> Enum.reduce([first], fn word, [line | done] ->
        longer = line <> " " <> word

        if width(longer, style) <= slot["width"],
          do: [longer | done],
          else: [word, line | done]
      end)
      |> Enum.reverse()

    case Enum.split(lines, room - 1) do
      {kept, []} -> kept
      {kept, left} -> kept ++ [Enum.join(left, " ")]
    end
  end

  # How wide `text` is set in `style`, from its characters' advances.
  defp width(text, style) do
    characters = @glyphs[style]["characters"]
    text |> String.graphemes() |> Enum.map(&characters[&1]["advance"]) |> Enum.sum()
  end

  defp draw(fleet_id, figures) do
    with {:ok, card} <- card(figures.cid) do
      (fleet_id <> ".png")
      |> share_file()
      |> opaque()
      |> set(figures.keys, "value", @slots["keys"], :left)
      |> set_lines(figures.treasury, "amount", @slots["treasury"])
      |> set(figures.name || "NONE YET", "name", @slots["name"], :centre)
      |> place(card, @slots["picture"])
      |> Operation.flatten!()
      |> Image.write_to_buffer(".png")
    end
  end

  # The latest Key's card as kept on IPFS, made to fit its place.
  defp card(nil), do: {:ok, nil}

  defp card(cid) do
    %{"width" => width, "height" => height} = @slots["picture"]

    with {:ok, png} <- KeyArt.kept(cid),
         {:ok, picture} <- Image.new_from_buffer(png) do
      picture
      |> Operation.thumbnail_image!(width, height: height)
      |> opaque()
      |> then(&{:ok, &1})
    end
  end

  defp place(base, nil, _slot), do: base

  defp place(base, picture, slot) do
    x = slot["x"] + div(slot["width"] - Image.width(picture), 2)
    y = slot["y"] + div(slot["height"] - Image.height(picture), 2)
    Operation.insert!(base, picture, x, y)
  end

  # Each of `lines` set in `style` on a line of its own, from the top of `slot`.
  defp set_lines(base, lines, style, slot) do
    height = @glyphs[style]["height"]

    lines
    |> Enum.with_index()
    |> Enum.reduce(base, fn {line, row}, base ->
      set(base, line, style, %{slot | "y" => slot["y"] + row * height, "height" => height}, :left)
    end)
  end

  # `text` set in `style` from its characters, side by side, then made
  # smaller if it is wider than its place, and put in its place: at its left
  # or its middle, by `align`.
  defp set(base, text, style, slot, align) do
    %{"height" => height, "pad" => pad, "characters" => characters} = @glyphs[style]
    strip = share_file("glyphs-#{style}.png")

    {cells, width} =
      text
      |> String.graphemes()
      |> Enum.map_reduce(0.0, fn character, pen ->
        %{"x" => x, "advance" => advance} = Map.fetch!(characters, character)
        cell = Operation.extract_area!(strip, x, 0, round(advance) + 2 * pad, height)
        {{cell, round(pen)}, pen + advance}
      end)

    canvas =
      Operation.black!(ceil(width) + 2 * pad, height, bands: 4)
      |> Operation.copy!(interpretation: :VIPS_INTERPRETATION_sRGB)

    line =
      Operation.composite!(
        [canvas | Enum.map(cells, &elem(&1, 0))],
        List.duplicate(:VIPS_BLEND_MODE_OVER, length(cells)),
        x: Enum.map(cells, &elem(&1, 1)),
        y: List.duplicate(0, length(cells))
      )

    room = slot["width"] + 2 * pad

    line =
      if Image.width(line) > room,
        do: Operation.resize!(line, room / Image.width(line)),
        else: line

    x =
      case align do
        :left -> slot["x"] - pad
        :centre -> slot["x"] + div(slot["width"] - Image.width(line), 2)
      end

    # On the place's bottom, so a line made smaller stays by its label.
    y = slot["y"] + slot["height"] - Image.height(line)
    Operation.composite2!(base, line, :VIPS_BLEND_MODE_OVER, x: x, y: y)
  end

  # A picture with nothing see-through, given the alpha the characters are
  # laid over it with.
  defp opaque(image) do
    image = if Image.has_alpha?(image), do: Operation.flatten!(image), else: image
    Operation.bandjoin_const!(image, [255.0])
  end

  # One of the pictures `render.mjs` drew, opened.
  defp share_file(name) do
    {:ok, image} =
      Image.new_from_file(Application.app_dir(:keyfleet, Path.join("priv/share", name)))

    image
  end
end
