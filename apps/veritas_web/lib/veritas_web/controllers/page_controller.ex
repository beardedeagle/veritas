defmodule Veritas.Web.PageController do
  @moduledoc """
  The pages the server renders directly.

  There are two, and both are small:

    * **`graphql`** — what a `GET /graphql` lands on. The GraphQL endpoint is
      POST-only, so a browser that navigates to it needs to be told that, and
      told where the IDE is. A bare 404 would be a dead end.

    * **`density`** — the density preference. It is a session value, because
      it is a preference of the person using the application rather than a
      property of a page.
  """
  use Veritas.Web, :controller

  @doc """
  The GraphQL endpoint reference.

  Rendered for `GET /graphql`. The endpoint itself answers `POST /graphql`.
  """
  def graphql(conn, _params) do
    render(conn, :graphql)
  end

  @doc """
  Sets the density preference and returns to the page the user came from.

  The return path is checked: only a local path is honoured, so this cannot be
  turned into an open redirect.
  """
  def density(conn, %{"density" => density} = params) do
    conn = put_session(conn, "veritas_density", sanitise_density(density))
    redirect(conn, external: safe_path(params["return_to"]))
  end

  defp sanitise_density("compact"), do: "compact"
  defp sanitise_density("comfortable"), do: "comfortable"
  defp sanitise_density(_other), do: "comfortable"

  defp safe_path(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path, else: "/"
  end

  defp safe_path(_path), do: "/"
end
