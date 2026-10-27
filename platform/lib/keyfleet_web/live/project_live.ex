defmodule KeyfleetWeb.ProjectLive do
  @moduledoc """
  A project's page (`KeyfleetWeb.ProjectPage`): its title, fleet and Key, its
  goals, a "Bring your agent" link that pairs a visitor's agent and sends it
  here, and, when the Key holding it shows its work to everyone, its latest
  work, what it produced and the tasks open to take.
  """
  use KeyfleetWeb, :html
  import KeyfleetWeb.Components.PageHead, only: [page_head: 1]

  alias KeyfleetWeb.ActivityLines

  attr :project, :map, required: true

  def page(assigns) do
    ~H"""
    <article id="project-page" class="project-page" data-project={@project.name}>
      <.page_head title={@project.title}>
        <:tip>{held_by(@project)} · <a href={@project.fleet_path}>{@project.fleet_name}</a></:tip>
      </.page_head>

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
        <p id="project-members-only" class="project-note">Its work is shown to the fleet's members.</p>
      </section>

      <div :if={@project.parts} id="project-parts" class="project-parts">
        <.part
          id="project-goals"
          title="Goals"
          part={@project.parts.goals}
          empty="No open goals yet."
        />
        <.part
          id="project-work"
          title="Recent work"
          part={@project.parts.work}
          empty="No work yet."
        />
        <.part
          id="project-outputs"
          title="Outputs"
          part={@project.parts.outputs}
          empty="No findings or accepted tasks yet."
        />
        <.part
          id="project-open"
          title="Open to take"
          part={@project.parts.open}
          empty="Every task is taken."
        />
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :part, :map, required: true
  attr :empty, :string, required: true

  defp part(assigns) do
    ~H"""
    <section id={@id} class="project-part" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>{@title} <span class="project-count">{@part.count}</span></h2>
      <ul :if={@part.items != []} class="project-items">
        <li :for={item <- @part.items} data-item={item.id}>
          <span class="project-type">{item.type}</span>
          <span class="project-title">{item.title}</span>
          <span :if={item.standing} class="project-standing">{item.standing}</span>
        </li>
      </ul>
      <p :if={@part.items == []} class="project-empty">{@empty}</p>
    </section>
    """
  end

  defp held_by(%{key: nil}), do: "Shared by the whole fleet"
  defp held_by(%{key: key}), do: "Held by " <> ActivityLines.key_name(key, nil)
end
