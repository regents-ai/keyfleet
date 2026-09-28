defmodule KeyfleetWeb.Time do
  @moduledoc "Times as people read them on a page. Every time is shown in UTC."

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
