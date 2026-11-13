import type {Hook} from "../hook_composition"
import type {Ask, HeatStage} from "../atlas/heat/stage"

type AtlasHeatHook = {
  el: HTMLElement
  stage?: HeatStage
  alive?: boolean
  pushEvent<Reply>(event: string, payload: object, onReply?: (reply: Reply) => void): void
  handleEvent<Payload>(event: string, callback: (payload: Payload) => void): void
}

/**
 * The Atlas as heat (`../atlas/heat/stage`), which loads as its own chunk.
 * Mount it on an element carrying the rows as JSON in `data-rows`, the window
 * the address names in `data-window` and `data-at`, and the kind of work in
 * `data-kind`, around a `phx-update="ignore"` stage. The picture asks the
 * page for what it shows as the reader moves, and reads it again when the
 * page says the fleet's work was counted again (`atlas:changed`).
 */
export const AtlasHeat: Hook = {
  mounted(this: AtlasHeatHook) {
    this.alive = true
    const ask: Ask = (event, payload, reply) => this.pushEvent(event, payload, reply)
    this.handleEvent("atlas:changed", () => this.stage?.changed())
    void import("../atlas/heat/stage").then(({createHeatStage}) => {
      if (this.alive) this.stage = createHeatStage(this.el, ask)
    })
  },
  updated(this: AtlasHeatHook) {
    this.stage?.update()
  },
  disconnected(this: AtlasHeatHook) {
    this.stage?.pause()
  },
  reconnected(this: AtlasHeatHook) {
    this.stage?.resume()
  },
  destroyed(this: AtlasHeatHook) {
    this.alive = false
    this.stage?.destroy()
  },
}
