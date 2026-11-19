defmodule Keyfleet.Seasons.Validations.Reason do
  @moduledoc """
  A pick's reason is one line a person types (`Keyfleet.Seasons.SeasonPick`),
  checked once Ash has trimmed it. The first rule it breaks refuses it
  (`Keyfleet.Seasons.Errors.ReasonError`, whose `rule` is the one named here):

    * `:plain`: valid UTF-8 on one line, with no control character and no
      format character, which draws nothing or turns the text around, but the
      joiner between two emoji of one (a family, the rainbow flag) and the tags
      of the flags of England, Scotland and Wales;
    * `:too_long`: at most `longest/0` UTF-16 units, as a text box counts what
      is typed (`KeyfleetWeb.BoxLimit`): one for most letters, two for an
      emoji, and an emoji joined from several counts them all;
    * `:blank`: at least one letter, digit, punctuation mark or symbol that
      shows, so neither only spaces and marks nor only the characters drawn as
      nothing though Unicode files them as letters or symbols (the Hangul
      fillers, the variation selectors, the blank Braille pattern, the null
      notehead);
    * `:marks`: no more than six marks, such as accents, in a row, so no letter
      carries a tower of them over the lines around it.

  Broken UTF-8 is refused before any other rule reads it, so a check never
  raises on it.
  """
  use Ash.Resource.Validation

  alias Keyfleet.Seasons.Errors.ReasonError

  @longest 500

  # One line of text drawn as it reads, the joiners and tags inside an emoji
  # aside.
  @plain ~r/
    \A(?:
      [^\p{Cc}\p{Cf}\p{Zl}\p{Zp}]
      | (?<=[\p{Extended_Pictographic}\x{FE0F}\p{Emoji_Modifier}]) \x{200D}
        (?=\p{Extended_Pictographic})
      | (?<=\x{1F3F4}) \x{E0067}\x{E0062}
        (?:\x{E0065}\x{E006E}\x{E0067} | \x{E0073}\x{E0063}\x{E0074} | \x{E0077}\x{E006C}\x{E0073})
        \x{E007F}
    )*\z
  /ux

  @shows ~r/(?![\p{DI}\x{2800}\x{1D159}])[\p{L}\p{N}\p{P}\p{S}]/u
  @tower ~r/\p{M}{7}/u

  @doc "The most UTF-16 units a reason holds."
  def longest, do: @longest

  @impl true
  def validate(changeset, _opts, _context) do
    case broken(Ash.Changeset.get_attribute(changeset, :reason)) do
      nil -> :ok
      rule -> {:error, ReasonError.exception(rule: rule)}
    end
  end

  defp broken(nil), do: nil

  defp broken(reason) do
    cond do
      not String.valid?(reason) -> :plain
      units(reason) > @longest -> :too_long
      not Regex.match?(@plain, reason) -> :plain
      not Regex.match?(@shows, reason) -> :blank
      Regex.match?(@tower, reason) -> :marks
      true -> nil
    end
  end

  defp units(reason), do: div(byte_size(:unicode.characters_to_binary(reason, :utf8, :utf16)), 2)
end
