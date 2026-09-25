defmodule KeyfleetWeb.TimeTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.Time

  @now ~U[2026-09-25 12:00:00Z]

  test "says how long ago something was in the largest whole unit" do
    assert ago(59) == "just now"
    assert ago(60) == "1 minute ago"
    assert ago(12 * 60 + 59) == "12 minutes ago"
    assert ago(3600) == "1 hour ago"
    assert ago(3 * 3600 + 1800) == "3 hours ago"
    assert ago(86_400) == "1 day ago"
    assert ago(2 * 86_400 + 3600) == "2 days ago"
  end

  defp ago(seconds), do: Time.ago(DateTime.add(@now, -seconds, :second), @now)
end
