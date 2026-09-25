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

  test "says when something was by its day in UTC, with the minute for today and yesterday" do
    assert Time.moment(~U[2026-09-25 00:00:00Z], @now) == "Today 00:00 UTC"
    assert Time.moment(~U[2026-09-25 09:05:59Z], @now) == "Today 09:05 UTC"
    assert Time.moment(~U[2026-09-24 23:59:00Z], @now) == "Yesterday 23:59 UTC"
    assert Time.moment(~U[2026-09-24 00:00:00Z], @now) == "Yesterday 00:00 UTC"
    assert Time.moment(~U[2026-09-23 23:59:59Z], @now) == "23 Sep"
    assert Time.moment(~U[2026-01-02 08:00:00Z], @now) == "2 Jan"
    assert Time.moment(~U[2025-12-31 23:00:00Z], @now) == "31 Dec 2025"
  end

  defp ago(seconds), do: Time.ago(DateTime.add(@now, -seconds, :second), @now)
end
