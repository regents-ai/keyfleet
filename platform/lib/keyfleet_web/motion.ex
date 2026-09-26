defmodule KeyfleetWeb.Motion do
  @moduledoc """
  Keyfleet's standard motion: one version of each kind of movement, the same
  as Patchbay's. Presses, server-rendered headlines and refusals move the same
  way on every page from `motion.ts`; a live part of a page names its version
  from here.
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
