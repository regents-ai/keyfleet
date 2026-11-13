defmodule KeyfleetWeb.PageTokenTest do
  # A connected page whose signed token lacks the client key is not a crash: the
  # page that reads the key (KeyfleetWeb.ShellLive) asks for one full request of
  # the page the token names, or of the public root when it names none. On 13 Nov
  # a tab drawn before the key was in the token crashed on /classic/1/worldline.
  use ExUnit.Case, async: true

  alias KeyfleetWeb.ShellLive
  alias Phoenix.LiveView.{Lifecycle, Socket}

  defp connected,
    do: %Socket{
      router: KeyfleetWeb.Router,
      transport_pid: self(),
      private: %{lifecycle: %Lifecycle{}}
    }

  test "a token without the client key asks for the page again" do
    session = %{
      "_csrf_token" => "form-token",
      "live_socket_id" => "session_authority:socket",
      "render_route" => "/classic/1/worldline?kind=vote"
    }

    assert {:ok, %Socket{redirected: {:redirect, %{to: "/classic/1/worldline?kind=vote"}}}} =
             ShellLive.mount(%{}, session, connected())

    assert {:ok, %Socket{redirected: {:redirect, %{to: "/"}}}} =
             ShellLive.mount(%{}, %{}, connected())
  end
end
