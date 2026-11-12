defmodule Keyfleet.LeftMessages do
  @moduledoc """
  Messages left for the site's team, Keyfleet's Agent Message: a signed agent
  or a signed-in person leaves one under a topic the site names, such as
  `agents`, and only the site's admins read them (`/admin/messages`). Nobody
  else ever sees one. They are not rooms' posts (`Keyfleet.Rooms`) or direct
  messages (`Keyfleet.Dms`). Leaving one is also the hosted agent tool
  `messages_leave` (`KeyfleetWeb.AgentTools.Account`).
  """

  use Ash.Domain

  resources do
    resource Keyfleet.LeftMessages.LeftMessage do
      define :leave_message, action: :leave
      define :agent_leave_message, action: :agent_leave, args: [:topic]
      define :list_left_messages, action: :newest
    end
  end
end
