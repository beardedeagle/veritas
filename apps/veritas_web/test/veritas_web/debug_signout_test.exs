defmodule Veritas.Web.SessionRoutesTest do
  @moduledoc """
  The shape of the session routes.

  The sign-out is reached two ways, and both are part of the contract:

    * `POST /session/signout` — the shape a browser form reaches without
      JavaScript, and the shape the account menu posts to;
    * `DELETE /session` — the shape a client reaches with the
      `X-Veritas-CSRF` header.

  The path is pinned here because something else depends on it, and a
  renamed route is a broken form.
  """
  use ExUnit.Case, async: true

  @routes Veritas.Web.Router.__routes__()

  test "the sign-out form path is POST /session/signout" do
    assert Enum.any?(@routes, fn route ->
             route.verb == :post and route.path == "/session/signout"
           end)
  end

  test "the sign-out client path is DELETE /session" do
    assert Enum.any?(@routes, fn route ->
             route.verb == :delete and route.path == "/session"
           end)
  end

  test "the sign-in is POST /session" do
    assert Enum.any?(@routes, fn route ->
             route.verb == :post and route.path == "/session"
           end)
  end
end
