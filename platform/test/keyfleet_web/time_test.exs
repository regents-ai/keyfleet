defmodule KeyfleetWeb.TimeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

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

  # Every message time is written again in its reader's own time zone once the
  # page is live (Sean, 21 October 2026: "it'd be good if each message showed
  # the user's local timezone"); before that the page writes it in UTC.
  test "a message time carries its moment for the reader's browser, in UTC words until then" do
    at = ~U[2026-10-21 00:03:00Z]
    stamp = render_component(&Time.local/1, id: "post-at", at: at, as: :stamp)

    assert stamp =~ ~s(id="post-at")
    assert stamp =~ ~s(phx-hook="LocalTime")
    assert stamp =~ ~s(datetime="2026-10-21T00:03:00Z")
    assert stamp =~ ~s(data-as="stamp")
    assert stamp =~ "21 October 2026 at 00:03 UTC"

    feed = render_component(&Time.local/1, id: "line-at", at: at, as: :clock, title_as: :moment)
    assert feed =~ ~s(data-title-as="moment")

    assert render_component(&Time.local/1, id: "day", at: at, as: :date) =~ "21 Oct 2026"
  end
end
