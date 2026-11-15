defmodule Keyfleet.Notebooks.PageTest do
  # Pages exported by marimo 0.25.2 (`marimo export html`, as the notebook
  # machine runs it), kept less their links to the viewer's files:
  # printed.html prints to stdout and stderr, shows markdown, raises, and has
  # a cell that depends on the one that raised; pictures.html shows a picture,
  # a picture in a bundle written as JSON text (as marimo shows a matplotlib
  # figure), a bundle written as an object, and a 20,000-character output.
  use ExUnit.Case, async: true

  alias Keyfleet.Notebooks.Page

  @pages Path.expand("../../support/fixtures/notebook_pages", __DIR__)
  @dot "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

  setup do
    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    %{budget: notebooks[:page_answer_max_bytes], value: notebooks[:page_value_max_bytes]}
  end

  # Costly failure: an agent told a run worked can't see that a cell raised,
  # or what the notebook printed on the way.
  test "cells carry what each printed, showed and raised, in the page's order", c do
    assert {:ok, cells, false} = Page.read(page("printed.html"), c.budget, c.value)
    assert [loaded, shown, raised, after_it] = cells

    assert loaded.console == [
             %{
               name: "stdout",
               mimetype: "text/plain",
               text: "loading rows\n",
               bytes: 13,
               cut: false
             },
             %{
               name: "stderr",
               mimetype: "text/plain",
               text: "two rows skipped\n",
               bytes: 17,
               cut: false
             }
           ]

    assert loaded.error == nil

    assert [%{mimetype: "text/markdown", text: markdown, cut: false}] = shown.outputs
    assert markdown =~ "<strong>Rows:</strong> 3"

    assert raised.error == %{
             kind: "exception",
             message: "division by zero",
             traceback: nil,
             cut: false
           }

    assert [%{name: "stderr", mimetype: "application/vnd.marimo+traceback", text: traceback}] =
             raised.console

    assert traceback =~ "ZeroDivisionError"
    assert after_it.error.message =~ "An ancestor raised an exception (ZeroDivisionError)"
  end

  # Costly failure: a picture's base64 fills the answer and crowds out the
  # cells after it.
  test "a picture is named with its size and no text, in a bundle too", c do
    assert {:ok, [dot, figure, bundle, _long], _truncated} =
             Page.read(page("pictures.html"), c.budget, c.value)

    picture = %{mimetype: "image/png", text: nil, bytes: byte_size(@dot), cut: false}
    assert dot.outputs == [picture]
    assert figure.outputs == [picture]

    assert bundle.outputs == [
             %{mimetype: "application/json", text: ~s({"rows":3}), bytes: 10, cut: false},
             %{mimetype: "text/html", text: "<b>three rows</b>", bytes: 17, cut: false}
           ]
  end

  # Costly failure: one long output makes the answer too large for the door
  # it goes through, or is cut without the agent being told.
  test "a long output is cut at the per-value limit and the page says it was cut", c do
    assert {:ok, cells, true} = Page.read(page("pictures.html"), c.budget, c.value)
    long = List.last(cells)

    assert [%{name: "stdout", text: "row 0\nrow 1\nrow 2\n", cut: false}] = long.console
    assert [%{mimetype: "text/html", text: text, bytes: bytes, cut: true}] = long.outputs
    assert byte_size(text) == c.value
    assert bytes > c.value
  end

  test "cells past the budget are left out, and the page says so", c do
    printed = page("printed.html")
    assert {:ok, [first | _rest], false} = Page.read(printed, c.budget, c.value)

    room = byte_size(Jason.encode!(first)) + 1
    assert Page.read(printed, room, c.value) == {:ok, [first], true}
  end

  # Costly failure: a page Keyfleet can't read is answered as a notebook with
  # no cells, and the agent takes it for a notebook that printed nothing.
  test "a page with no marimo session, or one of another version, is unreadable", c do
    printed = page("printed.html")

    other_version =
      String.replace(
        printed,
        ~s("script_metadata_hash": null}, "version": "1"}),
        ~s("script_metadata_hash": null}, "version": "2"})
      )

    assert other_version != printed

    for unreadable <- [
          "<p>run_0</p>",
          other_version,
          String.replace(printed, ~s("session"), ~s("other"))
        ] do
      assert Page.read(unreadable, c.budget, c.value) == {:error, :unreadable}
    end
  end

  defp page(name), do: File.read!(Path.join(@pages, name))
end
