defmodule Veritas.Web.AdminLive.Users do
  @moduledoc """
  Users and roles.

  `docs/04` §Navigation Model gives Admin a "Users and roles" screen. This is
  it: the accounts of the Workspace, the roles they hold, and the two things
  an administrator may do — create an account, and change what an account may
  do.

  ## Who may do it

  Only a Platform Admin holds `account:administrate` (`docs/02` §Roles), and
  nothing else does. The screen asks the policy at **every** event, the way
  `docs/09` §4's enforcement table asks, and the controls are hidden from
  everybody else. The check is the policy's, not the screen's: a screen that
  *shows* a role is not a screen that *enforces* one.

  ## There is no delete

  Disabling is not deleting. An account stays, because the Audit Log refers
  to the people who acted and an identity that has been deleted cannot be
  referred to. A disabled account cannot sign in and its open sessions are
  ended.

  ## The first account is not this screen's job

  The **first** account of a Workspace is created with the Workspace's
  bootstrap token: the operator proves they hold the Workspace before it has
  any people in it, because there is nobody to ask. This screen is inside the
  product, so the administrator is already signed in and their session is the
  proof. An administrator creating a later account needs no token, and
  `Veritas.Authn.create_account/3` is asked for none.

  ## The vocabulary

  The roles offered are the ones the policy enforces, from
  `Veritas.Core.Principal.role_names/0`. A role that is not in that map is
  not a role, so it is not offered here.
  """
  use Veritas.Web, :live_view

  alias Veritas.Authn
  alias Veritas.Core.{Policy, Principal}

  @impl true
  def mount(_params, _session, socket) do
    # The Workspace is the Principal's, not the URL's: a link carrying
    # another Workspace's name must not make this screen read it.
    workspace = socket.assigns[:principal_workspace]

    {:ok,
     assign(socket,
       page_title: "Users and roles",
       workspace: workspace,
       accounts: [],
       roles: role_choices(),
       matrix: matrix_rows(),
       matrix_types: matrix_types(),
       can_administer: false,
       error: nil
     )
     |> load_accounts()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("create", params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    case Policy.authorize(principal, "account:administrate", %{workspace: workspace}) do
      :allow ->
        attrs = %{
          "email" => params["email"],
          "display_name" => params["display_name"],
          "password" => params["password"],
          "roles" => selected_roles(params)
        }

        opts = [
          actor_id: principal && principal.id,
          reason: "the account was created by an administrator"
        ]

        case Authn.create_account(workspace, attrs, opts) do
          {:ok, created} ->
            {:noreply,
             socket
             |> put_flash(:info, "Created #{created.id}.")
             |> load_accounts()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{refusal(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def handle_event("save_roles", %{"account_id" => account_id} = params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    case Policy.authorize(principal, "account:administrate", %{workspace: workspace}) do
      :allow ->
        attrs = %{"roles" => selected_roles(params)}

        opts = [
          actor_id: principal && principal.id,
          reason: "the account's roles were changed by an administrator"
        ]

        case Authn.update_account(workspace, account_id, attrs, opts) do
          {:ok, _account} ->
            {:noreply,
             socket
             |> put_flash(:info, "The roles were saved.")
             |> load_accounts()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{refusal(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  @impl true
  def handle_event("toggle_disabled", %{"account_id" => account_id} = params, socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    case Policy.authorize(principal, "account:administrate", %{workspace: workspace}) do
      :allow ->
        disabled = params["disabled"] == "true"

        opts = [
          actor_id: principal && principal.id,
          reason: "the account was disabled by an administrator"
        ]

        case Authn.update_account(workspace, account_id, %{"disabled" => disabled}, opts) do
          {:ok, _account} ->
            {:noreply, socket |> put_flash(:info, "Saved.") |> load_accounts()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Refused: #{refusal(reason)}")}
        end

      {:deny, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{reason}")}
    end
  end

  defp load_accounts(socket) do
    workspace = socket.assigns.workspace
    principal = socket.assigns[:principal]

    accounts =
      case Authn.list_accounts(workspace) do
        {:ok, rows} -> rows
        {:error, _reason} -> []
      end

    assign(socket,
      accounts: accounts,
      can_administer:
        Policy.permitted?(principal, "account:administrate", %{workspace: workspace})
    )
  end

  # The role names the policy enforces, in the corpus's own spelling.
  defp role_choices do
    Principal.role_names()
    |> Enum.map(fn {_role, name} -> name end)
    |> Enum.sort()
  end

  # What each role may do, read from the policy rather than copied out of it.
  #
  # The matrix is `docs/02`'s own table — the policy carries it — and the
  # capabilities beside it are asked of the policy as well, so the screen
  # cannot drift from the decision the policy makes.
  defp matrix_rows do
    Policy.matrix()
    |> Enum.map(fn {role, letters} ->
      %{
        name: Principal.role_name(role),
        letters: Map.new(Policy.ticket_types(), fn type -> {type, letters[type] || "—"} end),
        capabilities: extra_capabilities(role)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp matrix_types do
    Policy.ticket_types()
    |> Enum.map(fn type ->
      type
      |> Atom.to_string()
      |> String.replace("_", " ")
      |> String.split(" ")
      |> Enum.map_join(" ", &String.capitalize/1)
    end)
  end

  # The capabilities a role holds that are not a ticket's. The ticket ones
  # are the matrix's own letters: R and A may write and move, any of the four
  # may read.
  defp extra_capabilities(role) do
    principal = Principal.new("matrix", "default", [role], kind: :human)

    Policy.capabilities()
    |> Enum.reject(&(&1 in ["ticket:read", "ticket:write", "ticket:transition"]))
    |> Enum.filter(fn capability ->
      Policy.permitted?(principal, capability, %{workspace: "default", ticket_type: :incident})
    end)
    |> Enum.join(", ")
  end

  # The roles the operator ticked. The checkboxes are named for the role, so
  # the form says which roles were chosen rather than the screen guessing. A
  # ticked box sends its value alongside the hidden "false" that stands for an
  # unticked one, so the pair arrives as a list.
  defp selected_roles(params) do
    params
    |> Enum.filter(fn {name, value} ->
      String.starts_with?(name, "role:") and ticked?(value)
    end)
    |> Enum.map(fn {name, _value} -> String.replace_prefix(name, "role:", "") end)
    |> Enum.sort()
  end

  defp ticked?("true"), do: true
  defp ticked?(values) when is_list(values), do: "true" in values
  defp ticked?(_value), do: false

  # The refusals the identity port gives, in words. Nothing here carries a
  # credential: the refusal says what was refused and nothing more.
  defp refusal(reason) when is_binary(reason), do: reason

  defp refusal(reason) do
    case reason do
      :account_exists -> "that email address already has an account"
      :invalid_email -> "that is not an email address"
      :password_required -> "the account needs a password"
      :password_breached -> "that password appears in a breach corpus and is refused"
      :account_missing -> "there is no such account"
      other -> inspect(other)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="mx-auto max-w-5xl px-6 py-10">
      <header class="mb-8 flex items-baseline justify-between">
        <div>
          <h1 class="text-3xl font-semibold tracking-tight">Users and roles</h1>
          <p class="mt-1 text-sm text-base-content/60">
            workspace <span class="font-mono">{@workspace}</span>
          </p>
        </div>
      </header>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">Create an account</h2>

        <Veritas.Web.CoreComponents.withheld
          capability="account:administrate"
          allowed={@can_administer}
          action="administer the accounts of a Workspace"
        >
          <p class="mt-1 text-xs leading-5 text-base-content/55">
            The account signs in with the email and the password given here. The
            password is not kept in any form the screen can read back.
          </p>

          <form id="account-create" phx-submit="create" class="mt-3 flex flex-wrap items-end gap-3">
            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">email</span>
              <input
                type="email"
                name="email"
                required
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">name</span>
              <input
                type="text"
                name="display_name"
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <label class="text-sm text-base-content/75">
              <span class="block text-xs uppercase tracking-wide text-base-content/70">password</span>
              <input
                type="password"
                name="password"
                required
                autocomplete="new-password"
                class="mt-1 rounded border border-base-300 px-2 py-1 text-sm"
              />
            </label>

            <fieldset class="text-sm text-base-content/75">
              <legend class="text-xs uppercase tracking-wide text-base-content/70">roles</legend>
              <div class="mt-1 flex flex-wrap gap-3">
                <label :for={role <- @roles} class="flex items-center gap-1 text-[13px]">
                  <input type="hidden" name={"role:#{role}"} value="false" />
                  <input type="checkbox" name={"role:#{role}"} value="true" />
                  {role}
                </label>
              </div>
            </fieldset>

            <button
              type="submit"
              class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
            >
              create
            </button>
          </form>
        </Veritas.Web.CoreComponents.withheld>
      </section>

      <p :if={!@can_administer} class="v-panel px-3 py-3 text-sm text-base-content/70">
        Only a Platform Admin may administer the accounts of a Workspace.
      </p>

      <section class="v-panel mb-6 px-3 py-3">
        <h2 class="text-[13px] font-semibold tracking-tight">What each role may do</h2>
        <p class="mt-1 text-xs leading-5 text-base-content/55">
          The role matrix from <span class="font-mono">docs/02</span>, as the
          policy carries it: R responsible, A accountable, C consulted, I
          informed. A role may write and move a ticket where it holds R or A;
          it may read one where it holds any of the four. Platform Admin
          configures policy and holds no transition rights.
        </p>

        <table class="mt-3 w-full text-[12px]">
          <thead>
            <tr class="border-b border-base-300 text-left text-base-content/55">
              <th class="py-1 pr-3 font-medium">role</th>
              <th :for={type <- @matrix_types} class="py-1 pr-3 font-medium">{type}</th>
              <th class="py-1 font-medium">also</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={role <- @matrix} class="border-b border-base-300/60">
              <td class="py-1 pr-3">{role.name}</td>
              <td :for={type <- Policy.ticket_types()} class="py-1 pr-3 font-mono">
                {role.letters[type]}
              </td>
              <td class="py-1 font-mono text-base-content/60">{role.capabilities}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <ul class="divide-y divide-base-300 border-y border-base-300">
        <li :for={account <- @accounts} class="py-4">
          <div class="flex items-baseline justify-between gap-6">
            <div class="min-w-0">
              <p class="font-medium">
                {account["display_name"] || account["email"]}
                <span
                  :if={account["disabled"] == true}
                  class="ml-2 text-[11px] uppercase tracking-wide text-base-content/45"
                >
                  disabled
                </span>
              </p>
              <p class="mt-1 font-mono text-xs text-base-content/60">
                {account["email"]}
                <span class="ml-2 text-base-content/45">{account["id"]}</span>
              </p>
              <p class="mt-1 text-[12px] text-base-content/60">
                {Enum.join(account["roles"] || [], ", ")}
              </p>
            </div>

            <Veritas.Web.CoreComponents.withheld
              capability="account:administrate"
              allowed={@can_administer}
              action="administer the accounts of a Workspace"
            >
              <div class="flex shrink-0 items-center gap-2">
                <form
                  phx-submit="toggle_disabled"
                  id={"disable-#{account["id"]}"}
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="account_id" value={account["id"]} />
                  <input type="hidden" name="disabled" value={to_string(account["disabled"] != true)} />
                  <button
                    type="submit"
                    class="rounded border border-base-300 px-3 py-1 text-sm hover:bg-base-100"
                  >
                    {if account["disabled"] == true, do: "enable", else: "disable"}
                  </button>
                </form>
              </div>
            </Veritas.Web.CoreComponents.withheld>
          </div>

          <Veritas.Web.CoreComponents.withheld
            capability="account:administrate"
            allowed={@can_administer}
            action="administer the accounts of a Workspace"
          >
            <form
              phx-submit="save_roles"
              id={"roles-#{account["id"]}"}
              class="mt-3 flex flex-wrap items-end gap-3"
            >
              <input type="hidden" name="account_id" value={account["id"]} />

              <fieldset class="text-sm text-base-content/75">
                <legend class="text-xs uppercase tracking-wide text-base-content/70">roles</legend>
                <div class="mt-1 flex flex-wrap gap-3">
                  <label :for={role <- @roles} class="flex items-center gap-1 text-[13px]">
                    <input type="hidden" name={"role:#{role}"} value="false" />
                    <input
                      type="checkbox"
                      name={"role:#{role}"}
                      value="true"
                      checked={role in (account["roles"] || [])}
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
          </Veritas.Web.CoreComponents.withheld>
        </li>
      </ul>

      <p :if={@accounts == []} class="py-10 text-center text-base-content/60">
        No accounts in this workspace yet.
      </p>
    </main>
    """
  end
end
