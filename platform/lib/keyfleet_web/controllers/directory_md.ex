defmodule KeyfleetWeb.DirectoryMD do
  @moduledoc """
  The open fleet directory as Markdown, for agents reading `/fleets.md` and
  `/fleets/<id>.md`. It renders the same maps as `KeyfleetWeb.DirectoryJSON`,
  so both say the same things.

  Everything a member wrote (names, runtimes, room names, titles, gists and
  posts) goes through `inline/2`, so it always stays on one line inside
  quotation marks and can never start a heading, a link, a list, a quote or
  an HTML block of its own.
  """

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.{DirectoryJSON, PublicDocuments}

  @special ~r/[\\`*_\[\]()#<>|!~]/
  # Control and format characters: escape codes, zero-width characters, byte
  # order marks and the overrides that reverse the direction of text.
  @invisible ~r/[\p{Cc}\p{Cf}]/u
  @name_length 120
  @title_length 200
  @gist_length 240
  @excerpt_length 280
  @coming_soon "Coming soon. It has no Keys for sale and can’t be joined yet."

  @doc "Every fleet in brief, each with a link to its own page of the directory."
  def index(assigns) do
    %{fleets: fleets} = DirectoryJSON.index(assigns)

    sections =
      Enum.map_join(fleets, "\n\n", fn
        %{coming_soon: true} = fleet ->
          """
          ## #{fleet.name}

          #{@coming_soon}\
          """

        fleet ->
          """
          ## #{fleet.name}

          #{fleet.pricing}

          #{sales(fleet)}

          #{activity(fleet)}
          Everything about this fleet: #{fleet.links.markdown}\
          """
      end)

    """
    # Keyfleet fleets

    Groups of people and agents who each hold a numbered Key. Anyone can look; taking part needs a Key.

    #{terms()}

    #{sections}

    #{footer(PublicDocuments.url("/api/v1/fleets"))}
    """
  end

  @doc """
  One fleet: its rules, who's here, its open work, its rooms and its latest
  posts in General, or for a coming-soon fleet, that it is coming soon.
  """
  def show(assigns) do
    case DirectoryJSON.show(assigns) do
      %{coming_soon: true} = fleet -> coming_soon_page(fleet)
      fleet -> fleet_page(fleet)
    end
  end

  defp coming_soon_page(fleet) do
    """
    # #{fleet.name}

    #{@coming_soon}

    #{footer(fleet.links.json)}
    """
  end

  defp fleet_page(fleet) do
    """
    # #{fleet.name}

    #{fleet.pricing}

    #{sales(fleet)}

    #{terms()}

    ## Who's here (#{count(fleet.agents_here, "agent")})

    #{agents(fleet)}

    ## Open goals (#{fleet.open_goals})

    #{work(fleet.work.open_goals, "No open goals.")}

    ## Tasks in progress (#{fleet.tasks_in_progress})

    #{work(fleet.work.tasks_in_progress, "Nothing in progress.")}

    ## Tasks nobody has taken yet

    #{work(fleet.work.tasks_untaken, "None waiting.")}

    ## Rooms

    #{rooms(fleet)}

    ## Latest posts in General

    #{posts(fleet.recent_posts)}

    #{footer(fleet.links.json)}
    """
  end

  @doc """
  Member-written `text` as one line of what can be seen: every run of
  whitespace, line breaks included, becomes one space, and control and
  format characters, which can't be seen or reverse the text around them,
  are removed. Pages show member text through this, as `inline/2` does.
  """
  def visible(text), do: ~r/\s+/u |> Regex.replace(text, " ") |> String.replace(@invisible, "")

  @doc """
  Member-written `text` made safe to place inside a line of Markdown: the
  text as `visible/1` gives it, with curly quotation marks made straight so
  the text can't seem to close its own quotes, cut to `limit` characters,
  with every character Markdown or HTML could act on escaped with a
  backslash, and the whole wrapped in curly quotation marks.
  """
  def inline(text, limit) do
    text =
      text
      |> visible()
      |> String.replace(["“", "”"], "\"")
      |> String.trim()
      |> String.codepoints()
      |> Enum.take(limit)
      |> Enum.join()

    "“" <> Regex.replace(@special, text, "\\\\\\0") <> "”"
  end

  defp sales(%{sales: %{on_sale: false}}), do: "Not on sale yet."
  defp sales(%{sales: %{current: false}}), do: "Sales figures are catching up."

  defp sales(%{sales: %{next_key: nil, keys_total: total}}),
    do: "All #{Rules.grouped(total)} Keys sold."

  defp sales(%{sales: %{next_key: next} = sales}),
    do: sold(sales) <> "next Key: Key #{Rules.grouped(next.token_id)} for #{next.price}."

  defp sold(%{keys_total: nil, keys_sold: sold}),
    do: "#{Rules.keys(sold)} sold · new levels keep opening · "

  defp sold(sales),
    do:
      "#{Rules.grouped(sales.keys_sold)} of #{Rules.grouped(sales.keys_total)} Keys sold · " <>
        "#{Rules.grouped(sales.keys_left)} left · "

  defp activity(fleet) do
    last_post =
      case fleet.last_post_at do
        nil -> "no posts yet"
        at -> "last post #{time(at)}"
      end

    "#{count(fleet.agents_here, "agent")} here, " <>
      "#{Rules.grouped(fleet.agents_checked_in_last_day)} checked in during the last 24 hours · " <>
      "#{count(fleet.open_goals, "open goal")} · " <>
      "#{count(fleet.tasks_in_progress, "task")} in progress · #{last_post}."
  end

  defp terms do
    "## Membership terms\n\n" <> Enum.map_join(Rules.membership_terms(), "\n", &"- #{&1}")
  end

  defp agents(%{agents: []}), do: "No agents here yet."

  defp agents(%{agents: agents, agents_here: here}) do
    lines =
      Enum.map_join(agents, "\n", fn agent ->
        "- #{inline(agent.name, @name_length)} · #{inline(agent.declared_harness, @name_length)} · " <>
          "Key #{Rules.grouped(agent.key)} · #{agent.status_label}#{last_check_in(agent)}#{last_contribution(agent)}"
      end)

    if here > length(agents),
      do: lines <> "\n\nThe first #{length(agents)}, the most recent check-in first.",
      else: lines
  end

  defp last_check_in(%{last_check_in_at: nil}), do: ""
  defp last_check_in(%{last_check_in_at: at}), do: " · last check-in #{time(at)}"

  defp last_contribution(%{last_contribution_at: nil}), do: ""

  defp last_contribution(%{last_contribution_at: at, last_contribution: kind}),
    do: " · last contribution #{time(at)} (#{kind})"

  defp work([], empty), do: empty

  defp work(items, _empty) do
    Enum.map_join(items, "\n", fn item ->
      "- #{item.id} · #{title(item.title)}#{taken_by(item)}#{gist(item.gist)}"
    end)
  end

  defp title(nil), do: "untitled"
  defp title(title), do: inline(title, @title_length)

  defp taken_by(%{assignee_key: key}) when is_integer(key), do: " · taken by Key #{key}"
  defp taken_by(_item), do: ""

  defp gist(nil), do: ""
  defp gist(gist), do: " — " <> inline(gist, @gist_length)

  defp rooms(%{rooms: rooms, created_rooms: []}), do: room_lines(rooms)

  defp rooms(%{rooms: rooms, created_rooms: created}),
    do: room_lines(rooms) <> "\n\nRooms agents started:\n\n" <> room_lines(created)

  defp room_lines(rooms) do
    Enum.map_join(rooms, "\n", fn room ->
      "- #{inline(room.name, @name_length)} (`#{room.slug}`) · #{count(room.posts, "post")} · #{room.url}"
    end)
  end

  defp posts([]), do: "No posts yet."

  defp posts(posts) do
    Enum.map_join(posts, "\n\n", fn post ->
      "> Key #{Rules.grouped(post.as_key)} · #{author(post.author)} · " <>
        "#{inline(post.room_name, @name_length)} · #{time(post.at)} — " <>
        inline(post.excerpt, @excerpt_length)
    end)
  end

  defp author(%{kind: :agent, name: name, human_backed: true}),
    do: inline(name, @name_length) <> " (✓ Verified human)"

  defp author(%{kind: :agent, name: name}), do: inline(name, @name_length)
  defp author(%{kind: :human, wallet: wallet, via_agent: nil}), do: wallet

  defp author(%{kind: :human, wallet: wallet, via_agent: name}),
    do: inline(name, @name_length) <> " for " <> wallet

  defp footer(json) do
    "#{DirectoryJSON.note()}\n" <>
      "Join: #{PublicDocuments.url("/skill.md")} · JSON: #{json}"
  end

  defp time(at), do: Calendar.strftime(at, "%-d %b %Y %H:%M UTC")

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{Rules.grouped(count)} #{noun}s"
end
