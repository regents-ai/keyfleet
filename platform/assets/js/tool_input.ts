// What every browser tool (WebMCP draft, document.modelContext) is called with,
// as priv/tool_manifest.json describes it, and the check each call gets: the
// browser does not check input against the schema, so a refusal here names
// the field and what it must be.

export type Schema = {
  type: "object"
  properties: Record<string, {type: "string"; description: string; enum?: string[]; maxLength?: number}>
  required: string[]
  additionalProperties: false
}

/** Why `input` doesn't fit `schema`, in words an agent can act on, or null when it does. */
export function inputProblem(input: unknown, schema: Schema): string | null {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    return "Send an object of named fields."
  }
  const fields = Object.keys(schema.properties)
  const unknown = Object.keys(input).find(key => !Object.hasOwn(schema.properties, key))
  if (unknown) {
    return fields.length
      ? `${unknown} is not a field of this tool; its fields are ${fields.join(", ")}.`
      : `${unknown} is not a field of this tool; it takes none.`
  }
  const missing = schema.required.find(key => !Object.hasOwn(input, key))
  if (missing) return `${missing} is required.`

  for (const [key, value] of Object.entries(input)) {
    const {enum: choices, maxLength} = schema.properties[key]
    if (typeof value !== "string") return `${key} must be a string.`
    // Half of an emoji's pair of units, alone, is no letter at all: the page's
    // live connection can't carry it, so nothing is sent.
    if (/\p{Surrogate}/u.test(value)) return `${key} has a broken character in it, such as half an emoji.`
    if (choices && !choices.includes(value)) return `${key} must be one of ${choices.join(", ")}.`
    // Counted as the page's box counts it, in UTF-16 units: an emoji is two.
    if (maxLength !== undefined && value.length > maxLength) {
      return `${key} takes at most ${maxLength} characters, an emoji counting as two.`
    }
  }
  return null
}
