defmodule Veritas.Web.Layouts do
  @moduledoc """
  The layouts of the application.

  There are two of them, and they do different jobs:

    * **`root`** — the document skeleton, and the place the application shell
      lives. The shell is chrome: the primary rail and the global top bar are
      the same on every screen, so they are rendered once, around the page.
      `root.html.heex` is where that happens.

    * **`app`** — the content frame for pages the server renders directly.
      A LiveView brings its own content and does not use this.

  The theme toggle lives with the shell, in `Veritas.Web.ShellComponents`,
  because a control that belongs to the chrome belongs to the chrome.
  """
  use Veritas.Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the content frame for a server-rendered page.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="mx-auto max-w-3xl">{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages to display"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
