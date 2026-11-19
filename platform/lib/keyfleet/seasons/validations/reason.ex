defmodule Keyfleet.Seasons.Validations.Reason do
  @moduledoc """
  A pick's reason is one line a person types (`Keyfleet.Seasons.SeasonPick`),
  checked once Ash has trimmed it. The first rule it breaks refuses it
  (`Keyfleet.Seasons.Errors.ReasonError`, whose `rule` is the one named here):

    * `:plain`: valid UTF-8 on one line, with no control character, no format
      character (which draws nothing or turns the text around) and none of
      the characters drawn as nothing, though Unicode files some of them as
      letters or symbols: every default-ignorable one (the Hangul fillers and
      the variation selectors among them), the blank Braille pattern and the
      null notehead. Only these are let through, each in its place:
        - a zero-width joiner or non-joiner, soft hyphen, or left-to-right or
          right-to-left mark, standing alone between two characters that are
          neither format characters nor spaces, as Persian, Sinhala and
          Bengali words hold them and the emoji of a family are joined;
        - a variation selector directly after a character it can vary: an
          emoji's (U+FE0E, U+FE0F) after an emoji, an ideograph's (U+E0100 to
          U+E01EF) after an ideograph, a Mongolian free variation selector
          after a Mongolian letter, and any other (U+FE00 to U+FE0D) after a
          letter, digit, punctuation mark or symbol;
        - a variation selector directly after a character Unicode has not yet
          assigned, a noncharacter aside, such as an emoji newer than the
          patterns know;
        - the tags of the flags of England, Scotland and Wales;
    * `:too_long`: at most `longest/0` UTF-16 units, as a text box counts what
      is typed (`KeyfleetWeb.BoxLimit`): one for most letters, two for an
      emoji, and an emoji joined from several counts them all;
    * `:blank`: at least one character that shows: a letter, digit,
      punctuation mark or symbol, or a character Unicode has not yet assigned,
      such as an emoji newer than the patterns know, so not only spaces and
      marks;
    * `:marks`: no more than six marks, such as accents, in a row, so no letter
      carries a tower of them over the lines around it.

  Broken UTF-8 is refused before any other rule reads it, so a check never
  raises on it.
  """
  use Ash.Resource.Validation

  alias Keyfleet.Seasons.Errors.ReasonError

  @longest 500

  # The characters drawn as nothing, though Unicode files some of them as
  # letters or symbols.
  @nothing ~S"\p{DI}\x{2800}\x{1D159}"

  # One line of text drawn as it reads: no control, format or line-separating
  # character, and none drawn as nothing but those let through in their place.
  @plain ~r/
    \A(?:
      [^\p{Cc}\p{Cf}\p{Zl}\p{Zp}#{@nothing}]
      | (?<=[^\p{Cf}\p{Z}]) [\x{200C}\x{200D}\x{00AD}\x{200E}\x{200F}] (?=[^\p{Cf}\p{Z}])
      | (?<=\p{Emoji}) [\x{FE0E}\x{FE0F}]
      | (?<=\p{Ideographic}) [\x{E0100}-\x{E01EF}]
      | (?<=\p{Mongolian}) (?<=\p{L}) [\x{180B}-\x{180D}\x{180F}]
      | (?<=[\p{L}\p{N}\p{P}\p{S}]) [\x{FE00}-\x{FE0D}]
      | (?<=\p{Cn}) (?<!\p{Noncharacter_Code_Point}) \p{Variation_Selector}
      | (?<=\x{1F3F4}) \x{E0067}\x{E0062}
        (?:\x{E0065}\x{E006E}\x{E0067} | \x{E0073}\x{E0063}\x{E0074} | \x{E0077}\x{E006C}\x{E0073})
        \x{E007F}
    )*+\z
  /ux

  # A character that shows. `:plain` has already refused every character drawn
  # as nothing but those it lets through, and none of those is a letter, digit,
  # punctuation mark, symbol or unassigned, so none is taken here for one.
  @shows ~r/[\p{L}\p{N}\p{P}\p{S}] | (?!\p{Noncharacter_Code_Point})\p{Cn}/ux
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
