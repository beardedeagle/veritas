defmodule Veritas.Web.SessionHTML do
  @moduledoc """
  The sign-in page.

  It is deliberately **not** the application's layout: the sign-in page is
  the one page a person sees before they have a Principal, and the shell
  around it would be chrome for a screen that cannot yet read anything.
  """
  use Veritas.Web, :html

  embed_templates "session_html/*"
end
