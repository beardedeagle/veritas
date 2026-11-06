defmodule Veritas.Web.Shell.SectionLive do
  @moduledoc """
  A path that names no screen.

  Every section the rail shows has a screen now, so this is what an unknown
  path lands on: it says there is no page there and takes the reader back to
  the Overview, rather than rendering a page that pretends.

  It used to hold the "planned section" pages — the shape of what was coming,
  so the owner could see the product's outline. That work is done: the Admin
  section has a landing page that says which of its panels exist, and the
  Audit Log is a screen.

  ## What this page does not do

  It does not fake a number, and it does not pretend a screen exists. There
  is no empty table with a "Coming soon" header pretending to be a queue.
  """

  use Veritas.Web, :live_view

  @impl true
  def mount(%{"section" => key}, _session, socket) do
    # The CMDB has a screen; its rail entry points at the CI list.
    if key == "cmdb" do
      {:ok, push_navigate(socket, to: "/cmdb/cis")}
    else
      {:ok,
       socket
       |> assign(page_title: "No page here", section: nil, key: key)
       |> put_flash(:error, "There is no page at /#{key}.")
       |> push_navigate(to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-3xl px-6 py-10">
      <h1 class="text-2xl font-semibold tracking-tight">There is no page here</h1>
      <p class="mt-2 text-sm text-base-content/60">
        <span class="font-mono">/{@key}</span> names no screen. The sections the rail
        shows all have one.
      </p>
      <p class="mt-4">
        <.link navigate="/" class="text-sm underline">Back to the Overview</.link>
      </p>
    </main>
    """
  end
end
