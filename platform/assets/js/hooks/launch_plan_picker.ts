import type {Hook} from "../hook_composition"

type LaunchPlanPickerHook = Hook & {
  el: HTMLElement
  cleanup?: () => void
}

/** The form fields a launch plan fills in, each named as its option's data and its input. */
export const planFields = ["name", "symbol", "description", "website", "image", "raise"] as const

type PlanField = (typeof planFields)[number]

/** An option of the picker: its value is the plan version's digest, empty for no plan. */
export type PlanOption = {value: string; dataset: Readonly<Record<string, string | undefined>>}

/** What choosing an option puts in the launch form. */
export type PlanChoice = {
  digest: string
  fields: Partial<Record<PlanField, string>>
}

/**
 * What choosing `option` does to the launch form. A plan fills in its six
 * launch details and makes the proposal point to its version; "Don't use a
 * plan" makes it point nowhere and leaves the details as they are.
 */
export function planChoice(option: PlanOption): PlanChoice {
  if (option.value === "") return {digest: "", fields: {}}

  const {dataset} = option
  return {
    digest: option.value,
    fields: Object.fromEntries(planFields.map(name => [name, dataset[name] ?? ""])),
  }
}

/**
 * The launch form's plan picker. Choosing a plan copies its launch details
 * into the form and its digest into the hidden field the proposal points
 * with, before the form's change reaches the server, which builds the
 * proposal from the form and says which plan it points to. It never touches
 * the Propose button: every press still goes to the wallet.
 */
export const LaunchPlanPicker: Hook = {
  mounted(this: LaunchPlanPickerHook) {
    const root = this.el

    const change = (event: Event) => {
      const select = event.target as HTMLSelectElement
      if (select.dataset?.launchPlans === undefined) return

      const choice = planChoice(select.options[select.selectedIndex])
      for (const [name, value] of Object.entries(choice.fields)) field(root, name).value = value
      field(root, "digest").value = choice.digest
    }

    root.addEventListener("change", change)
    this.cleanup = () => root.removeEventListener("change", change)
  },

  destroyed(this: LaunchPlanPickerHook) {
    this.cleanup?.()
  },
}

function field(root: HTMLElement, name: string): HTMLInputElement | HTMLTextAreaElement {
  return root.querySelector<HTMLInputElement | HTMLTextAreaElement>(`[name="${name}"]`)!
}
