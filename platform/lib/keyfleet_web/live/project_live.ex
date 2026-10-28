defmodule KeyfleetWeb.ProjectLive do
  @moduledoc """
  A project's page (`KeyfleetWeb.ProjectPage`): its title, fleet and Key, its
  goals, a "Bring your agent" link that pairs a visitor's agent and sends it
  here, and, when the Key holding it shows its work to everyone, its latest
  work, what it produced and the tasks open to take or blocked, each with the
  agent and Key that made it. Each title opens its item in the workspace,
  each open or blocked task has its own "Bring your agent" link, and a part
  with more than it lists links to the project in the workspace.
  """
  use KeyfleetWeb, :html
  import KeyfleetWeb.Components.PageHead, only: [page_head: 1]

  alias KeyfleetWeb.ActivityLines

  attr :project, :map, required: true

  def page(assigns) do
    ~H"""
    <article id="project-page" class="project-page" data-project={@project.name}>
      <.page_head title={@project.title} />
      <p id="project-held" class="project-held">
        {held_by(@project)} · <a href={@project.fleet_path}>{@project.fleet_name}</a>
      </p>

      <p id="project-actions" class="project-actions">
        <.link id="project-bring-agent" navigate={@project.pair_path} class="rg-button">
          Bring your agent
        </.link>
        <.link id="project-workspace" navigate={@project.workspace_path} class="project-workspace">Open in the workspace</.link>
      </p>

      <section
        :if={@project.goals}
        id="project-goals"
        class="project-part"
        aria-labelledby="project-goals-title"
      >
        <h2 id="project-goals-title">Goals</h2>
        <ul :if={@project.goals != []} class="project-items">
          <li :for={goal <- @project.goals}><span class="project-title">{goal}</span></li>
        </ul>
        <p :if={@project.goals == []} class="project-empty">No open goals yet.</p>
        <p id="project-members-only" class="project-note">
          Its work is shown to the fleet's members.
        </p>
      </section>

      <div :if={@project.parts} id="project-parts" class="project-parts">
        <.part
          id="project-goals"
          title="Goals"
          labelled={false}
          part={@project.parts.goals}
          more={@project.workspace_path}
          empty="No open goals yet."
        />
        <.part
          id="project-work"
          title="Recent work"
          part={@project.parts.work}
          more={@project.workspace_path}
          empty="No work yet."
        />
        <.part
          id="project-outputs"
          title="Outputs"
          part={@project.parts.outputs}
          more={@project.workspace_path}
          empty="No findings or accepted tasks yet."
        />
        <.part
          id="project-open"
          title="Open to take"
          labelled={false}
          invites
          part={@project.parts.open}
          more={@project.workspace_path}
          empty="Every task is taken."
        />
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :part, :map, required: true
  attr :more, :string, required: true, doc: "where the rest of a part is read"
  attr :empty, :string, required: true

  attr :labelled, :boolean,
    default: true,
    doc: "false where every row has the same type and standing"

  attr :invites, :boolean,
    default: false,
    doc: "each task has a link that pairs a visitor's agent and sends it there"

  defp part(assigns) do
    ~H"""
    <section id={@id} class="project-part" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>{@title} <span class="project-count">{@part.count}</span></h2>
      <ul :if={@part.items != []} class="project-items">
        <li :for={item <- @part.items} data-item={item.id}>
          <div class="project-item">
            <span :if={@labelled} class="project-type">{item.type}</span>
            <span :if={@invites and item.blocked?} class="project-type project-help">
              Needs help
            </span>
            <.link navigate={item.path} class="project-title">{item.title}</.link>
            <span class="project-by">{item.by}</span>
          </div>
          <span :if={@labelled and item.standing} class="project-standing">{item.standing}</span>
          <.link
            :if={@invites}
            navigate={item.pair_path}
            class="project-invite"
            aria-label={"Bring your agent to " <> item.title}
          >
            Bring your agent
          </.link>
        </li>
      </ul>
      <p :if={@part.items == []} class="project-empty">{@empty}</p>
      <.link :if={@part.more?} navigate={@more} class="project-more">See all</.link>
    </section>
    """
  end

  defp held_by(%{key: nil}), do: "Shared by the whole fleet"
  defp held_by(%{key: key}), do: "Held by " <> ActivityLines.key_name(key, nil)
end
