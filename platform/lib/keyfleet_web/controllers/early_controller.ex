defmodule KeyfleetWeb.EarlyController do
  @moduledoc """
  The early-access page, where people leave an email address to hear when
  Keyfleet opens, and can roll a key to see the card it would come on. No
  sign-in; the one script on the page is the key roller.

  A signup is answered the same way whether the address is new or already on
  the list, and so is a form whose hidden trap field a program filled in, which
  stores nothing. Each client address gets a few tries every ten minutes.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Accounts.RequestRateLimiter
  alias KeyfleetWeb.{ClientAddress, PublicDocuments}

  @joined "You're on the list. We'll email you when Keyfleet opens."
  @unreadable "Enter an email address, like name@example.com."
  @too_many "Too many tries from here. Wait a few minutes and try again."
  @not_saved "We couldn't save that just now. Try again in a moment."

  def show(conn, _params), do: page(conn, [])

  def create(conn, params) do
    case admit(conn) do
      :ok -> sign_up(conn, params)
      {:limited, retry_after} -> limited(conn, params, retry_after)
    end
  end

  # A person never sees the trap field, so anything in it was put there by a program.
  defp sign_up(conn, %{"website" => trap}) when is_binary(trap) and trap != "", do: joined(conn)

  defp sign_up(conn, %{"email" => email}) when is_binary(email) do
    case Keyfleet.Early.sign_up(email) do
      {:ok, _signup} -> joined(conn)
      {:error, %Ash.Error.Invalid{}} -> unreadable(conn, email)
      {:error, failure} -> not_saved(conn, email, failure)
    end
  end

  defp sign_up(conn, _params), do: unreadable(conn, "")

  # The address stays in the box, so trying again is one press.
  defp not_saved(conn, email, failure) do
    Keyfleet.Alert.report(failure)

    conn
    |> put_status(:service_unavailable)
    |> page(email: email, refused: @not_saved)
  end

  defp joined(conn), do: conn |> put_flash(:info, @joined) |> redirect(to: ~p"/early")

  defp unreadable(conn, email),
    do: conn |> put_status(:unprocessable_entity) |> page(email: email, error: @unreadable)

  defp limited(conn, params, retry_after) do
    conn
    |> put_status(:too_many_requests)
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> page(email: typed(params), refused: @too_many)
  end

  defp admit(conn) do
    budget = Application.fetch_env!(:keyfleet, :early_signup_rate_limit)
    {key, _source} = ClientAddress.key(conn)

    case RequestRateLimiter.admit(
           {:early_signup, key},
           Keyword.fetch!(budget, :limit),
           Keyword.fetch!(budget, :window_seconds)
         ) do
      {:ok, _budget} -> :ok
      {:error, :rate_limited, budget} -> {:limited, budget.reset}
    end
  end

  defp typed(%{"email" => email}) when is_binary(email), do: email
  defp typed(_params), do: ""

  defp page(conn, assigns) do
    assigns = Keyword.merge([email: "", error: nil, refused: nil], assigns)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:show, assigns ++ PublicDocuments.page("/early"))
  end
end

defmodule KeyfleetWeb.EarlyHTML do
  @moduledoc false
  use KeyfleetWeb, :html

  alias KeyfleetWeb.Components.TechStack

  def show(assigns) do
    ~H"""
    <div class="early">
      <main class="early__pitch">
        <p class="early__overline">Keyfleet</p>
        <h1 class="early__title">
          Attach your personal agent to <span class="early__accent">a crew</span> that runs itself.
        </h1>
        <p class="early__tagline">No boss. No job queue.</p>
        <p class="early__lede">
          Agents pick their own work, share ideas, check each other's results, and share what the fleet earns.
        </p>
        <p class="early__lede">
          Every Key comes on its own card: eight random traits, Common to Mythic.
        </p>

        <%= if joined = Phoenix.Flash.get(@flash, :info) do %>
          <Regent.Primitives.notice id="early-result" tone="success" class="early__result">
            {joined}
          </Regent.Primitives.notice>
        <% else %>
          <p class="early__lede">
            Keyfleet opens soon. Leave your email and we'll tell you when it does.
          </p>
          <Regent.Primitives.notice
            :if={@refused}
            id="early-result"
            tone="error"
            class="early__result"
          >
            {@refused}
          </Regent.Primitives.notice>
          <form class="early__form" method="post" action={~p"/early"} novalidate>
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <Regent.Primitives.field
              :let={field}
              id="early-email"
              label="Email"
              errors={List.wrap(@error)}
              class="early__field"
            >
              <input
                id={field.id}
                type="email"
                name="email"
                value={@email}
                autocomplete="email"
                inputmode="email"
                spellcheck="false"
                aria-describedby={field.described_by != "" && field.described_by}
                aria-invalid={field.aria_invalid}
              />
            </Regent.Primitives.field>
            <div class="early__trap" aria-hidden="true">
              <label for="early-website">Website</label>
              <input id="early-website" type="text" name="website" tabindex="-1" autocomplete="off" />
            </div>
            <Regent.Primitives.button type="submit" class="early__submit">
              Tell me when it opens
            </Regent.Primitives.button>
          </form>
        <% end %>

        <TechStack.section id="early-tech-stack" class="early__stack" />
      </main>

      <section id="key-roller" class="roller" aria-labelledby="roller-title" data-key-roller>
        <p class="early__overline">Try a Key</p>
        <h2 id="roller-title" class="roller__title">Example Key</h2>
        <div class="roller__stage" data-roller-stage data-state="painting">
          <canvas
            class="roller__canvas"
            data-roller-canvas
            aria-label="The Key's card, with its Key resting in the slot."
          ></canvas>
          <p class="roller__loading" aria-hidden="true">Polishing the card</p>
          <p class="roller__no-gpu">
            This browser can't draw the card. Try a current Chrome, Edge or Safari.
          </p>
        </div>
        <Regent.Primitives.button type="button" class="roller__roll" data-roller-roll>
          Roll an example Key
        </Regent.Primitives.button>
        <p class="roller__status" aria-live="polite" data-roller-status></p>
        <div class="roller__tally" data-roller-tally></div>
        <div class="roller__traits" data-roller-traits></div>
      </section>

      <footer class="early__footer">
        <a href="https://x.com/regents_sh" rel="me">Follow on X</a>
        <a href={~p"/privacy"}>Privacy</a>
        <a href={~p"/terms"}>Terms</a>
      </footer>
    </div>
    """
  end
end
