defmodule KeyfleetWeb.Time do
  @moduledoc "Times as people read them on a page. Every time is shown in UTC."

  @doc """
  How long before `now` the moment `at` was: "just now" within a minute, then
  "12 minutes ago", "3 hours ago" or "2 days ago".
  """
  def ago(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(now, at)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> plural(div(seconds, 60), "minute")
      seconds < 86_400 -> plural(div(seconds, 3600), "hour")
      true -> plural(div(seconds, 86_400), "day")
    end
  end

  defp plural(1, unit), do: "1 #{unit} ago"
  defp plural(count, unit), do: "#{count} #{unit}s ago"

  @doc """
  When `at` was, as seen on `now`'s day: "Today 14:03 UTC", "Yesterday 09:10
  UTC", then the day alone, "22 Sep", with its year when that is not this
  year's, "22 Sep 2025".
  """
  def moment(%DateTime{} = at, %DateTime{} = now) do
    days = Date.diff(DateTime.to_date(now), DateTime.to_date(at))

    cond do
      days == 0 -> Calendar.strftime(at, "Today %H:%M UTC")
      days == 1 -> Calendar.strftime(at, "Yesterday %H:%M UTC")
      at.year == now.year -> Calendar.strftime(at, "%-d %b")
      true -> Calendar.strftime(at, "%-d %b %Y")
    end
  end
end
