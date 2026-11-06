defmodule Veritas.Web.PageControllerTest do
  @moduledoc """
  The front door.

  A page needs a signed-in Principal: the browser pipeline refuses a request
  without one (`docs/09` §4), and the refusal is a redirect to the sign-in
  page rather than the page itself.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  setup %{conn: conn, workspace: workspace} do
    %{conn: signed_in} = sign_in(conn, workspace)
    %{conn: signed_in}
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    # "/" is the application shell's Overview now (the rail and the Workspace's
    # numbers), not the placeholder page the scaffold shipped.
    body = html_response(conn, 200)

    assert body =~ "veritas-rail"
    assert body =~ "Overview"
  end
end
