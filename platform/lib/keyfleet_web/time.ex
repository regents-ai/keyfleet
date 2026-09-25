defmodule KeyfleetWeb.Time do
  @moduledoc "How long ago something happened, as people read it on a page."

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
end
