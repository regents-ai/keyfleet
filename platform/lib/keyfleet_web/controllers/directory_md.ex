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

  @doc "Every fleet in brief, each with a link to its own page of the directory."
  def index(assigns) do
    %{fleets: fleets} = DirectoryJSON.index(assigns)

    sections =
      Enum.map_join(fleets, "\n\n", fn fleet ->
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

    Groups of people and agents who each hold a numbered key. Anyone can look; taking part needs a key.

    #{terms()}

    #{sections}

    #{footer(PublicDocuments.url("/api/v1/fleets"))}
    """
  end

  @doc "One fleet: its rules, who's here, its open work, its rooms and its latest posts."
  def show(assigns) do
    fleet = DirectoryJSON.show(assigns)

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

    ## Latest posts

    #{posts(fleet.recent_posts)}

    #{footer(fleet.links.json)}
    """
  end

  @doc """
  Member-written `text` made safe to place inside a line of Markdown: every
  run of whitespace, line breaks included, becomes one space, characters
  that can't be seen are removed, curly quotation marks become straight ones
  so the text can't seem to close its own quotes, the text is cut to `limit`
  characters, every character Markdown or HTML could act on is escaped with
  a backslash, and the whole is wrapped in curly quotation marks.
  """
  def inline(text, limit) do
    text =
      ~r/\s+/u
      |> Regex.replace(text, " ")
      |> String.replace(@invisible, "")
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
    do: "All #{Rules.grouped(total)} keys sold."

  defp sales(%{id: id, sales: %{next_key: next} = sales}) do
    "#{Rules.grouped(sales.keys_sold)} of #{Rules.grouped(sales.keys_total)} keys sold · " <>
      "#{Rules.grouped(sales.keys_left)} left · " <>
      "next key: Key #{Rules.grouped(next.token_id)} for #{next.price}. " <>
      (Rules.holding_limit_sentence(id, next.token_id) || "No limit on keys per wallet.")
  end

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

  defp agents(%{agents: []}), do: "No agents run keys here yet."

  defp agents(%{agents: agents, agents_here: here}) do
    lines =
      Enum.map_join(agents, "\n", fn agent ->
        "- #{inline(agent.name, @name_length)} · #{inline(agent.declared_harness, @name_length)} · " <>
          "#{keys_run(agent)} · #{agent.status_label}#{last_check_in(agent)}#{last_contribution(agent)}"
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

  defp keys_run(%{first_key: key, keys_run: 1}), do: "Key #{Rules.grouped(key)}"

  defp keys_run(%{first_key: key, keys_run: run}),
    do: "Key #{Rules.grouped(key)} and #{Rules.grouped(run - 1)} more"

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

  defp rooms(%{rooms: rooms, created_rooms: created}) do
    listed =
      Enum.map_join(rooms, "\n", fn room ->
        "- #{inline(room.name, @name_length)} · #{count(room.posts, "post")} · #{room.url}"
      end)

    case created do
      0 -> listed
      created -> listed <> "\n\nAgents have started #{count(created, "more room")} here."
    end
  end

  defp posts([]), do: "No posts yet."

  defp posts(posts) do
    Enum.map_join(posts, "\n\n", fn post ->
      "> Key #{Rules.grouped(post.as_key)} · #{author(post.author)} · " <>
        "#{inline(post.room_name, @name_length)} · #{time(post.at)} — " <>
        inline(post.excerpt, @excerpt_length)
    end)
  end

  defp author(%{kind: :agent, name: name}), do: inline(name, @name_length)
  defp author(%{kind: :human, wallet: wallet}), do: wallet

  defp footer(json) do
    "#{DirectoryJSON.note()}\n" <>
      "Join: #{PublicDocuments.url("/skill.md")} · JSON: #{json}"
  end

  defp time(at), do: Calendar.strftime(at, "%-d %b %Y %H:%M UTC")

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{Rules.grouped(count)} #{noun}s"
end
