import type {Hook} from "../hook_composition"
import type {Ask, RiverStage} from "../atlas/river/stage"

type AtlasRiverHook = {
  el: HTMLElement
  stage?: RiverStage
  alive?: boolean
  pushEvent<Reply>(event: string, payload: object, onReply?: (reply: Reply | null) => void): void
  handleEvent<Payload>(event: string, callback: (payload: Payload) => void): void
}

/**
 * The Atlas as a river (`../atlas/river/stage`), which loads as its own chunk.
 * Mount it on an element carrying the rows as JSON in `data-rows`, the window
 * the address names in `data-window` and `data-at`, and the kind of work in
 * `data-kind`, around a `phx-update="ignore"` stage. The picture asks the
 * page for what it shows as the reader moves, and reads it again when the
 * page says the fleet's work was counted again (`atlas:changed`).
 */
export const AtlasRiver: Hook = {
  mounted(this: AtlasRiverHook) {
    this.alive = true
    // The page answers nothing to a question it does not take, as once the
    // reader may no longer read or its own read failed; the river asks again later.
    const ask: Ask = <Reply>(event: string, payload: object, reply?: (reply: Reply) => void) =>
      this.pushEvent<Reply>(event, payload, answer => {
        if (answer !== null && this.alive) reply?.(answer)
      })
    this.handleEvent("atlas:changed", () => this.stage?.changed())
    void import("../atlas/river/stage").then(({createRiverStage}) => {
      if (this.alive) this.stage = createRiverStage(this.el, ask)
    })
  },
  updated(this: AtlasRiverHook) {
    this.stage?.update()
  },
  disconnected(this: AtlasRiverHook) {
    this.stage?.pause()
  },
  reconnected(this: AtlasRiverHook) {
    this.stage?.resume()
  },
  destroyed(this: AtlasRiverHook) {
    this.alive = false
    this.stage?.destroy()
  },
}
