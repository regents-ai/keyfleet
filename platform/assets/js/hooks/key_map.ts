import type {Hook} from "../hook_composition"
import type {KeyMapStage} from "./key_map/key_map_stage"
import type {LayoutKind} from "./key_map/layouts"
import type {KeyMapSnapshot} from "./key_map/state"

type KeyMapHook = {
  el: HTMLElement
  pushEvent<Reply>(event: string, payload: unknown, onReply: (reply: Reply) => void): void
  ready?: () => void
  cleanup?: () => void
}

/**
 * A fleet's key map. The map itself loads as its own chunk; this hook asks the
 * page for the fleet's keys on mount and after every reconnect, and reports the
 * key a viewer chooses. Mount it on a `phx-update="ignore"` element carrying
 * `data-layout`.
 */
export const KeyMap: Hook = {
  mounted(this: KeyMapHook) {
    let stage: KeyMapStage | undefined
    let alive = true
    this.ready = () => this.pushEvent<KeyMapSnapshot>("keymap_ready", {}, snapshot => stage?.load(snapshot))
    void import("./key_map/key_map_stage").then(({createKeyMapStage}) => {
      if (!alive) return
      stage = createKeyMapStage(this.el, {
        layout: this.el.dataset.layout as LayoutKind,
        // A reply callback keeps a press made while offline from raising an error.
        select: key => this.pushEvent("select_key", {token_id: key}, () => {}),
      })
      this.ready?.()
    })
    this.cleanup = () => {
      alive = false
      stage?.destroy()
    }
  },

  reconnected(this: KeyMapHook) {
    this.ready?.()
  },

  destroyed(this: KeyMapHook) {
    this.cleanup?.()
  },
}
