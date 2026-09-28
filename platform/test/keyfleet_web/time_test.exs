defmodule KeyfleetWeb.TimeTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.Time

  @now ~U[2026-09-25 12:00:00Z]

  test "says when something was by its day in UTC, with the minute for today and yesterday" do
    assert Time.moment(~U[2026-09-25 00:00:00Z], @now) == "Today 00:00 UTC"
    assert Time.moment(~U[2026-09-25 09:05:59Z], @now) == "Today 09:05 UTC"
    assert Time.moment(~U[2026-09-24 23:59:00Z], @now) == "Yesterday 23:59 UTC"
    assert Time.moment(~U[2026-09-24 00:00:00Z], @now) == "Yesterday 00:00 UTC"
    assert Time.moment(~U[2026-09-23 23:59:59Z], @now) == "23 Sep"
    assert Time.moment(~U[2026-01-02 08:00:00Z], @now) == "2 Jan"
    assert Time.moment(~U[2025-12-31 23:00:00Z], @now) == "31 Dec 2025"
  end
end
