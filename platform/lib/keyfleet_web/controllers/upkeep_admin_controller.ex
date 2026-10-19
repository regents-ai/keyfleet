defmodule KeyfleetWeb.UpkeepAdminController do
  @moduledoc """
  The routine upkeep's switch at /admin/upkeep, for Credits admins
  (`KeyfleetWeb.ErrorsAdmin` turns everyone else away): whether it is running,
  the account that pays its network fees, and one button that pauses or
  resumes it at once, in the admin's name. A plain page with one form and no
  script. The form says which way it turns, so a second press of the same
  button changes nothing.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Treasury

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:show,
      paused: Treasury.upkeep_paused?(),
      operator: Treasury.upkeep_operator()
    )
  end

  def update(conn, %{"upkeep" => "pause"}) do
    Treasury.pause_upkeep!(conn.assigns.admin_account.id)
    redirect(conn, to: ~p"/admin/upkeep")
  end

  def update(conn, %{"upkeep" => "resume"}) do
    Treasury.resume_upkeep!(conn.assigns.admin_account.id)
    redirect(conn, to: ~p"/admin/upkeep")
  end
end

defmodule KeyfleetWeb.UpkeepAdminHTML do
  @moduledoc false
  use KeyfleetWeb, :html

  alias KeyfleetWeb.Components.AddressLinks

  def show(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-brand="platform" data-theme={@theme}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>Routine upkeep · Keyfleet</title>
        <link rel="stylesheet" href={~p"/assets/js/app.css"} />
      </head>
      <body>
        <Regent.Structure.frame>
          <Regent.Structure.row rail={false}>
            <main id="upkeep-admin" class="rg-inset proposals-page">
              <section class="proposals-panel" aria-labelledby="upkeep-admin-title">
                <h1 id="upkeep-admin-title">
                  Routine upkeep: {if @paused, do: "Paused", else: "Running"}
                </h1>
                <p class="proposals-detail">
                  Every 5 minutes Keyfleet presses each fleet’s Treasury buttons that are due. Pausing stops it at once; people can still press every button.
                </p>
                <dl class="proposals-facts">
                  <div>
                    <dt>Pays network fees</dt>
                    <dd :if={@operator} id="upkeep-admin-operator" class="proposals-address">
                      <code title={@operator}>{RegentFormat.short_address(@operator)}</code>
                      <a
                        href={AddressLinks.basescan(@operator)}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        View on BaseScan
                      </a>
                    </dd>
                    <dd :if={is_nil(@operator)} id="upkeep-admin-operator">Not set up</dd>
                  </div>
                </dl>
                <form id="upkeep-admin-switch" method="post" action={~p"/admin/upkeep"}>
                  <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                  <input
                    type="hidden"
                    name="upkeep"
                    value={if @paused, do: "resume", else: "pause"}
                  />
                  <Regent.Primitives.button type="submit">
                    {if @paused, do: "Resume", else: "Pause"}
                  </Regent.Primitives.button>
                </form>
              </section>
            </main>
          </Regent.Structure.row>
        </Regent.Structure.frame>
      </body>
    </html>
    """
  end
end
