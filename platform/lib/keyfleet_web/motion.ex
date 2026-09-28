defmodule KeyfleetWeb.Motion do
  @moduledoc """
  The standard motion: the version of each kind of movement the real pages
  use, picked in the motion lab at `/animations`. Presses, panels, headlines
  and card lists move the same way on every page from `assets/js/motion.ts`;
  a live part of a page names its version from here in `data-variant`.

  Every Regent site shares these versions. A part the product has no place
  for yet (a note that peels, a stamp that thunks) keeps its version here and
  in the lab, so a page that gains one moves the same way as every other site.
  """

  @standard %{
    "drawer" => "spring",
    "sheet" => "spring",
    "menu" => "pop",
    "note" => "peel",
    "toast" => "pop",
    "list" => "bounce",
    "count" => "roll",
    "stamp" => "thunk",
    "tabs" => "glide",
    "headline" => "rise",
    "grid" => "cascade"
  }

  @doc "Every part's standard version."
  def standard, do: @standard

  @doc "The standard version of one part, such as `\"list\"`."
  def standard(part), do: Map.fetch!(@standard, part)
end
