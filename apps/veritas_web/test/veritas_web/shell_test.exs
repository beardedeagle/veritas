defmodule Veritas.Web.ShellTest do
  @moduledoc """
  The application shell, tested on behaviour.

  The shell is the frame every screen sits in: a navigation rail, a top bar
  and a landing page. Two things about it are worth a test, and neither is
  about pixels:

    * **the rail is the navigation model.** `docs/04` §Navigation Model fixes
      the eight sections and where they point. A section that is missing from
      the rail is a section nobody can reach.

    * **the landing page's numbers are measurements.** They come from the
      domain layer — the same path the Incident screens and GraphQL take — so
      a figure on the front door can be checked against the domain. A
      hardcoded number would pass a screenshot and fail this.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Core.Tickets
  alias Veritas.Web.Shell.Context

  # Every screen needs a signed-in Principal: the browser pipeline refuses a
  # request without one, and the LiveView socket is authorised at mount
  # (`docs/09` §4).
  setup %{conn: conn, workspace: workspace} do
    %{conn: signed_in} = sign_in(conn, workspace)
    %{conn: signed_in}
  end

  # The eight sections of `docs/04` §Navigation Model, with the paths the
  # corpus gives them. Admin is the section's landing page: it says which of
  # its panels exist, and the panels themselves are under it.
  @sections [
    {"Overview", "/"},
    {"Incidents", "/incidents"},
    {"Service Desk", "/requests"},
    {"CMDB", "/cmdb/cis"},
    {"Changes", "/changes"},
    {"Delivery", "/programs"},
    {"Security", "/vulnerabilities"},
    {"Admin", "/admin"}
  ]

  describe "the navigation rail" do
    test "shows every section of the corpus, and links it to the right route", %{
      conn: conn,
      workspace: workspace
    } do
      conn = get(conn, ~p"/?workspace=#{workspace}")
      rail = html_response(conn, 200)

      assert rail =~ "veritas-rail", "the shell must render a navigation rail"

      # The rail carries the corpus's eight sections and no more.
      assert length(Regex.scan(~r/class="v-rail-link"/, rail)) == 8,
             "the rail must carry the eight sections of the corpus"

      for {label, path} <- @sections do
        assert rail =~ label, "the rail must show the #{label} section"

        assert rail =~ ~s{href="#{path}" class="v-rail-link"},
               "the rail must link #{label} to #{path}"
      end
    end

    test "the section list is the corpus's eight sections" do
      sections = Context.sections(nil)

      assert length(sections) == 8,
             "the corpus fixes eight sections; the shell has #{length(sections)}"

      for {label, path} <- @sections do
        assert Enum.any?(sections, &(&1.label == label and &1.path == path)),
               "#{label} → #{path} is missing from the section list"
      end
    end

    test "a section with a screen is marked as live, and none is marked as planned" do
      sections = Context.sections(nil)

      # Every section the rail shows has a screen now, so none of them may
      # carry the "Soon" badge. A badge is a claim about the product, and a
      # claim that is false is the same disease as a screen that explains a
      # mechanism this build does not have.
      assert Enum.filter(sections, &(&1.status == :planned)) == [],
             "a section with a screen must not be marked as planned"

      assert Enum.all?(sections, &(&1.status == :live))
    end
  end

  describe "the landing page" do
    test "its numbers are the domain's numbers, not a figure somebody typed", %{
      conn: conn,
      workspace: workspace
    } do
      # Two open Incidents, one of them past `new`.
      first = open_incident(workspace, %{"title" => "Checkout is down"})
      open_incident(workspace, %{"title" => "Disk is filling"})

      {:ok, _} =
        Tickets.transition(
          workspace,
          first["id"],
          "acknowledged",
          Veritas.Core.Principal.new("u1", workspace, [:incident_manager])
        )

      {:ok, view, _static} = live(conn, ~p"/?workspace=#{workspace}")
      html = render(view)

      assert tile(html, "Open Incidents") == "2",
             "the landing page must count the two open Incidents the domain reports"

      assert tile(html, "Unacknowledged") == "1"
      assert tile(html, "Acknowledged") == "1"
    end

    test "it reports the Audit Log chain as the domain verifies it", %{
      conn: conn,
      workspace: workspace
    } do
      open_incident(workspace, %{"title" => "Checkout is down"})

      {:ok, view, _static} = live(conn, ~p"/?workspace=#{workspace}")
      html = render(view)

      assert tile(html, "Audit Log chain") == "intact"
    end

    test "an empty Workspace says nothing is open, rather than reporting a number it did not measure",
         %{conn: conn, workspace: workspace} do
      {:ok, view, _static} = live(conn, ~p"/?workspace=#{workspace}")
      html = render(view)

      assert tile(html, "Open Incidents") == "0"
      assert html =~ "All clear"
    end
  end

  describe "a section without a screen" do
    test "the Audit Log is a screen, not a planned page", %{conn: conn} do
      # The Audit Log was a placeholder and is now a screen: the rail sends
      # the operator to a real page, not to a "not built" notice.
      conn = get(conn, ~p"/audit")

      assert conn.status == 200, "the Audit Log is a page, not a 404"
      body = html_response(conn, 200)

      assert body =~ "Audit Log"
      refute body =~ "Planned section"
      refute body =~ "404"
      refute body =~ "not found"
    end

    test "an unknown section is refused and sends the user home", %{conn: conn} do
      conn = get(conn, ~p"/no_such_section")

      assert redirected_to(conn) == "/"
    end
  end

  describe "the GraphiQL IDE" do
    test "is mounted and reachable", %{conn: conn} do
      conn = get(conn, ~p"/graphql/i")

      assert conn.status == 200
      body = html_response(conn, 200)

      assert body =~ "GraphiQL"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # The value of a KPI tile, read from the rendered markup: the label and the
  # value are adjacent elements, and the value is the only thing between the
  # value element's tags.
  defp tile(html, label) do
    case Regex.run(~r/#{Regex.escape(label)}<\/p>\s*<p[^>]*>\s*([^<]*?)\s*<\/p>/s, html) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_rail(html) do
    case Regex.run(~r/id="veritas-rail"(.*?)<\/nav>/s, html) do
      [_, rail] -> rail
      _ -> nil
    end
  end
end
