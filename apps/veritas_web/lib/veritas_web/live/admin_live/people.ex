defmodule Veritas.Web.AdminLive.People do
  @moduledoc """
  The people, and what they may do here.

  ## Two populations, told apart

  The company's people come from the company's **directory**, and Veritas does
  not own that directory and does not bundle an identity provider: it consumes
  one through `Veritas.Core.Directory`, the same shape as the storage adapter
  and the model-provider adapters.

  Beside them are Veritas's own **local accounts** — the break-glass path,
  the ones that hold a password and sign in with it.

  Every row says which kind of person it is. A screen that mixes the two
  without saying so is a screen that cannot be read.

  ## What Veritas owns, and what it does not

  The directory owns the person. Veritas owns the **grants**: the roles, the
  Workspace membership, and whether the person's access here is on or off. So
  granting a role to somebody in the directory writes a Principal in Veritas —
  the corpus's *an external subject maps to a Veritas Principal* — and it
  never writes to the directory.

  ## With no directory

  There is no directory in this build by default, and the screen says so in
  one plain line, with what to configure. An empty table pretending to be a
  directory would say "this company has no people", which is a different and
  false statement.

  ## The access an adapter needs

  The adapter says which scopes it needs (`Veritas.Core.Directory.required_scopes/0`),
  and the screen shows them: the operator grants the access **after** seeing
  what it is for.
  """
  use Veritas.Web, :live_view

  alias Veritas.Authn
  alias Veritas.Core.{Directory, Policy, Principal}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns[:principal_workspace]
    principal = socket.assigns[:principal]

    {:ok,
     socket
     |> assign(
       page_title: "People",
       workspace: workspace,
       can_administer:
         Policy.permitted?(principal, "account:administrate", %{workspace: workspace}),
       accounts: [],
       directory: [],
       directory_state: :none,
       roles: Map.values(Principal.role_names()),
       scopes: []
     )
     |> load()}
  end

  @impl true
  def handle_event("save_roles", params, socket) do
    with :allow <-
           Policy.authorize(socket.assigns[:principal], "account:administrate", %{
             workspace: socket.assigns.workspace
           }),
         {:ok, account_id} <- resolve_account(socket.assigns.workspace, params),
         {:ok, _account} <-
           Authn.update_account(
             socket.assigns.workspace,
             account_id,
             %{"roles" => selected_roles(params)},
             actor_opts(socket.assigns[:principal])
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "The roles were saved.")
       |> load()}
    else
      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def handle_event("toggle_disabled", params, socket) do
    with :allow <-
           Policy.authorize(socket.assigns[:principal], "account:administrate", %{
             workspace: socket.assigns.workspace
           }),
         {:ok, account_id} <- resolve_account(socket.assigns.workspace, params),
         {:ok, _account} <-
           Authn.update_account(
             socket.assigns.workspace,
             account_id,
             %{"disabled" => params["disabled"] == "true"},
             actor_opts(socket.assigns[:principal])
           ) do
      {:noreply, socket |> put_flash(:info, "Saved.") |> load()}
    else
      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def handle_event("create_in_directory", params, socket) do
    case Directory.create(%{"email" => params["email"], "name" => params["name"]}) do
      {:ok, person} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{person.email} is in the directory.")
         |> load()}

      {:error, :no_directory} ->
        {:noreply, put_flash(socket, :error, "There is no directory configured.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "The directory refused: #{inspect(reason)}")}
    end
  end

  # The accounts, the directory, and the scopes the adapter wants.
  defp load(socket) do
    workspace = socket.assigns.workspace

    {directory, directory_state} =
      case Directory.list() do
        {:ok, people} -> {people, :listed}
        {:error, :no_directory} -> {[], :none}
        {:error, reason} -> {[], {:failed, reason}}
      end

    assign(socket,
      accounts: accounts(workspace),
      directory: directory,
      directory_state: directory_state,
      scopes: Directory.required_scopes()
    )
  end

  defp accounts(workspace) do
    case Authn.list_accounts(workspace) do
      {:ok, accounts} -> accounts
      {:error, _reason} -> []
    end
  end

  # The account a grant is written to: the one the operator named, or the
  # Principal Veritas holds for somebody in the directory — created the first
  # time the operator grants them something.
  defp resolve_account(workspace, params) do
    case params["account_id"] do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        email = params["person_email"] || ""
        subject = params["person_subject"]

        case account_id(workspace, email) do
          # The Principal Veritas already holds for this person.
          {:ok, account_id} ->
            {:ok, account_id}

          {:error, :no_such_person} ->
            # The first grant writes the Principal: the corpus's *an external
            # subject maps to a Veritas Principal*.
            case Authn.create_principal(
                   workspace,
                   %{
                     "email" => email,
                     "external_subject" => subject,
                     "roles" => selected_roles(params)
                   },
                   actor_opts(nil)
                 ) do
              {:ok, principal} -> {:ok, principal.id}
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  defp account_id(workspace, email) do
    case Authn.account_id(workspace, email) do
      {:ok, id} ->
        {:ok, id}

      {:error, _reason} ->
        {:error, :no_such_person}
    end
  end

  defp selected_roles(params) do
    for {key, "true"} <- params, String.starts_with?(key, "role:"), do: role_name(key)
  end

  defp role_name("role:" <> name), do: name

  defp actor_opts(principal) do
    [
      actor_id: principal && principal.id,
      reason: "the roles were changed by an administrator"
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-8">
        <h1 class="text-3xl font-semibold tracking-tight">People</h1>
        <p class="mt-1 text-sm text-base-content/60">
          workspace <span class="font-mono">{@workspace}</span> — the people who may
          act here, and the people the company keeps.
        </p>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">The company's directory</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          The directory is the company's own. Veritas reads it and does not write to
          it: the people live there, and the grants live here.
        </p>

        <p :if={@directory_state == :none} class="mt-3 text-sm text-base-content/70">
          No directory is configured. To administer the company's people, set
          <span class="font-mono">config :veritas_core, :directory</span>
          to an
          adapter — for example <span class="font-mono">{Veritas.Core.Directory.Google}</span>
          with the path to
          a service account key and the subject to act as.
        </p>

        <p :if={match?({:failed, _reason}, @directory_state)} class="mt-3 text-sm text-error">
          The directory could not be read: {inspect(elem(@directory_state, 1))}.
        </p>

        <ul :if={@scopes != []} class="mt-3 text-xs text-base-content/60">
          <li>This adapter needs these access scopes:</li>
          <li :for={scope <- @scopes} class="font-mono">{scope}</li>
        </ul>

        <table :if={@directory != []} class="mt-3 w-full text-left text-sm">
          <thead class="text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="py-1 pr-3 font-medium">person</th>
              <th class="py-1 pr-3 font-medium">kind</th>
              <th class="py-1 pr-3 font-medium">roles here</th>
              <th class="py-1 font-medium">access</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={person <- @directory} class="border-t border-base-200 align-top">
              <td class="py-1 pr-3">
                <div>{person.name || person.email}</div>
                <div class="font-mono text-xs text-base-content/60">{person.email}</div>
              </td>
              <td class="py-1 pr-3 text-xs text-base-content/70">directory identity</td>
              <td class="py-1 pr-3 text-xs">{roles_of(grants_for(person, @accounts))}</td>
              <td class="py-1 text-xs">{access_of(grants_for(person, @accounts))}</td>
            </tr>
          </tbody>
        </table>

        <ul :if={@directory != []} class="mt-3 flex flex-col gap-3">
          <li :for={person <- @directory} class="rounded border border-base-200 px-3 py-2">
            <form
              phx-submit="save_roles"
              id={"directory-roles-#{person.id}"}
              class="flex flex-wrap items-end gap-3"
            >
              <input type="hidden" name="person_email" value={person.email} />
              <input type="hidden" name="person_subject" value={person.id} />

              <fieldset class="text-sm text-base-content/75">
                <legend class="text-xs uppercase tracking-wide text-base-content/70">
                  roles here
                </legend>
                <div class="mt-1 flex flex-wrap gap-3">
                  <label :for={role <- @roles} class="flex items-center gap-1 text-[13px]">
                    <input type="hidden" name={"role:#{role}"} value="false" />
                    <input
                      type="checkbox"
                      name={"role:#{role}"}
                      value="true"
                      checked={role in granted_roles(person, @accounts)}
                    />
                    {role}
                  </label>
                </div>
              </fieldset>

              <button
                type="submit"
                class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
              >
                save roles
              </button>
            </form>

            <form
              phx-submit="toggle_disabled"
              id={"directory-access-#{person.id}"}
              class="mt-2 flex items-center gap-2"
            >
              <input type="hidden" name="person_email" value={person.email} />
              <input type="hidden" name="person_subject" value={person.id} />

              <input
                :if={grants_for(person, @accounts)}
                type="hidden"
                name="account_id"
                value={grants_for(person, @accounts)["id"]}
              />
              <input
                type="hidden"
                name="disabled"
                value={to_string(access_of(grants_for(person, @accounts)) != "disabled")}
              />
              <button
                type="submit"
                class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
              >
                {access_label(person, @accounts)}
              </button>
            </form>
          </li>
        </ul>

        <p :if={@directory != []} class="mt-3 text-xs text-base-content/55">
          Granting a role to somebody in the directory writes a Principal here. It is
          audited, and it names the profile in force.
        </p>
      </section>

      <section class="v-panel px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Local accounts</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          Veritas's own accounts. They hold a password, they sign in with it, and
          they are the path that works when nothing else answers.
        </p>

        <table class="mt-3 w-full text-left text-sm">
          <thead class="text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="py-1 pr-3 font-medium">account</th>
              <th class="py-1 pr-3 font-medium">kind</th>
              <th class="py-1 pr-3 font-medium">roles</th>
              <th class="py-1 font-medium">access</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={account <- @accounts} class="border-t border-base-200 align-top">
              <td class="py-1 pr-3">
                <div>{account["display_name"]}</div>
                <div class="font-mono text-xs text-base-content/60">{account["email"]}</div>
              </td>
              <td class="py-1 pr-3 text-xs text-base-content/70">local account</td>
              <td class="py-1 pr-3 text-xs">{Enum.join(account["roles"] || [], ", ")}</td>
              <td class="py-1 text-xs">{if account["disabled"], do: "disabled", else: "enabled"}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </main>
    """
  end

  # The grants Veritas holds for somebody in the directory: the account row
  # with their email.
  defp grants_for(person, accounts) do
    Enum.find(accounts, fn account -> account["email"] == person.email end)
  end

  defp roles_of(nil), do: "none"

  defp roles_of(account), do: Enum.join(account["roles"] || [], ", ")

  defp granted_roles(person, accounts) do
    case grants_for(person, accounts) do
      nil -> []
      account -> account["roles"] || []
    end
  end

  defp access_of(nil), do: "no grants yet"
  defp access_of(account), do: if(account["disabled"], do: "disabled", else: "enabled")

  # The button's label: what pressing it will do.
  defp access_label(person, accounts) do
    case grants_for(person, accounts) do
      nil -> "grant"
      account -> if account["disabled"], do: "enable", else: "disable"
    end
  end
end
