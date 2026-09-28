defmodule KeyfleetWeb.Motion do
  @moduledoc """
  Keyfleet's standard motion: one version of each kind of movement, the same
  as the template's. Presses, menus, dialogs and server-rendered headlines move
  the same way on every page from `assets/js/motion.ts`, and the fleet's drawers
  from its `Slides` island; a live part of a page names its version from here
  in `data-variant`.
  """

  @standard %{
    "drawer" => "spring",
    "sheet" => "spring",
    "menu" => "pop",
    "list" => "bounce",
    "count" => "roll",
    "grid" => "cascade"
  }

  @doc "The standard version of one part, such as `\"list\"`."
  def standard(part), do: Map.fetch!(@standard, part)
end
