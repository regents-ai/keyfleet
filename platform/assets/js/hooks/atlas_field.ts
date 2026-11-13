import type {Hook} from "../hook_composition"
import type {Ask, FieldStage} from "../atlas/field/stage"

type AtlasFieldHook = {
  el: HTMLElement
  stage?: FieldStage
  alive?: boolean
  pushEvent<Reply>(event: string, payload: object, onReply?: (reply: Reply) => void): void
  handleEvent<Payload>(event: string, callback: (payload: Payload) => void): void
}

/**
 * The Atlas as a field (`../atlas/field/stage`), which loads as its own chunk.
 * Mount it on an element carrying the rows as JSON in `data-rows`, the kinds
 * in `data-kinds`, the window in `data-window`, `data-from` and `data-to`,
 * and the kind of work in `data-kind`, around a `phx-update="ignore"` stage.
 * The field asks the page for what it shows as the reader moves, and reads it
 * again when the page says the fleet's work was counted again
 * (`atlas:changed`).
 */
export const AtlasField: Hook = {
  mounted(this: AtlasFieldHook) {
    this.alive = true
    const ask: Ask = (event, payload, reply) => this.pushEvent(event, payload, reply)
    this.handleEvent("atlas:changed", () => this.stage?.changed())
    void import("../atlas/field/stage").then(({createFieldStage}) => {
      if (this.alive) this.stage = createFieldStage(this.el, ask)
    })
  },
  updated(this: AtlasFieldHook) {
    this.stage?.update()
  },
  disconnected(this: AtlasFieldHook) {
    this.stage?.pause()
  },
  reconnected(this: AtlasFieldHook) {
    this.stage?.resume()
  },
  destroyed(this: AtlasFieldHook) {
    this.alive = false
    this.stage?.destroy()
  },
}
