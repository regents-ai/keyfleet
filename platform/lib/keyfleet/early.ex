defmodule Keyfleet.Early do
  @moduledoc """
  The early-access list: the email addresses people leave on `/early` while
  Keyfleet is closed, kept only to tell them when it opens.
  """
  use Ash.Domain

  resources do
    resource Keyfleet.Early.Signup do
      define :sign_up, action: :sign_up, args: [:email]
    end
  end
end
