defmodule Veritas.Core.Principal do
  @moduledoc """
  The acting identity: **who** is making a request.

  A Principal is what the rest of the product authorises. It carries an
  identifier, the Workspace the identity acts in, and the Roles it holds
  **in that Workspace**. `docs/09` §4 says a Principal maps to Workspace-scoped
  Roles and that one Principal may hold different roles in different
  Workspaces without becoming an escalation path — which is exactly why the
  Workspace lives *inside* the Principal rather than beside it.

  ## The kinds of Principal

  The corpus names five kinds of actor (`docs/02` §Attribution): a human
  principal, an Agentic Actor, a Plugin capability, an Adapter, and the
  platform as `system`. Only the first three are principals in the sense of
  "something that can be held responsible for an action"; an Adapter and the
  platform act on their own authority rather than as someone's proxy, and
  they arrive through the ingestion path rather than through a session.

  The kinds that exist in this slice are:

    * `:human` — a local account. It signs in with a password and holds a
      session.
    * `:agentic` — an Agentic Actor. It holds no R and no A anywhere
      (`docs/02` §Roles), so its output is a proposal and never an action.
    * `:service` — a non-human principal for a Plugin, a Connector or a
      scheduled job. It has no password and no interactive session; the
      corpus gives it no delegation by default (`docs/09` §3).
    * `:system` — the platform itself.

  ## The roles are a closed vocabulary

  The role names are the ones `docs/02` §Role matrix spells, and **only**
  those. `docs/09` §4 records a finding: `docs/02` and `docs/08` define
  different role sets, `docs/02` is normative, and *"no implementation may
  pick a vocabulary"* until `docs/08` is amended. So this module carries the
  `docs/02` set verbatim, and an unknown role is not a role — it is ignored,
  and a Principal holding only unknown roles holds no authority at all.

  Roles are held as atoms here and as the corpus's own strings in the store,
  because the store is a record of what the corpus says and the code is not.
  """

  @typedoc "What kind of actor this is."
  @type kind :: :human | :agentic | :service | :system

  @typedoc "A role from the `docs/02` set."
  @type role ::
          :requester
          | :service_desk_agent
          | :service_desk_manager
          | :incident_manager
          | :change_manager
          | :cab_chair
          | :cab_member
          | :problem_manager
          | :vulnerability_owner
          | :ci_steward
          | :platform_admin
          | :auditor
          | :agentic_actor

  @typedoc "The acting identity."
  @type t :: %__MODULE__{
          id: String.t(),
          workspace: String.t(),
          roles: [role()],
          kind: kind(),
          display_name: String.t() | nil
        }

  defstruct [:id, :workspace, :display_name, kind: :human, roles: []]

  # The `docs/02` role set, spelled the way the corpus spells it. The atom is
  # the code's name and the string is the corpus's; the store carries the
  # string, because the store is a record of the corpus and not of the code.
  @role_names %{
    requester: "Requester",
    service_desk_agent: "Service Desk Agent",
    service_desk_manager: "Service Desk Manager",
    incident_manager: "Incident Manager",
    change_manager: "Change Manager",
    cab_chair: "CAB Chair",
    cab_member: "CAB Member",
    problem_manager: "Problem Manager",
    vulnerability_owner: "Vulnerability Owner",
    ci_steward: "CI Steward",
    platform_admin: "Platform Admin",
    auditor: "Auditor",
    agentic_actor: "Agentic Actor"
  }

  @doc """
  The role names the corpus uses, keyed by the atom the code uses.

  The map is the vocabulary. A role that is not in it is not a role.
  """
  @spec role_names() :: %{role() => String.t()}
  def role_names, do: @role_names

  @doc """
  The corpus's spelling of a role, or nil when the atom is not a role.
  """
  @spec role_name(role()) :: String.t() | nil
  def role_name(role), do: Map.get(@role_names, role)

  @doc """
  The atom for a role the corpus names, or nil when the name is not one.

  The comparison is case-insensitive and ignores surrounding space, because a
  role that arrives from a directory or a configuration file should not be
  refused over a capital letter. A name that is not in the vocabulary is
  **not** silently mapped onto a nearby role: it is ignored, and a Principal
  that holds only ignored roles holds no authority.
  """
  @spec known_role(String.t() | atom() | nil) :: role() | nil
  def known_role(nil), do: nil

  def known_role(role) when is_atom(role) do
    if Map.has_key?(@role_names, role), do: role, else: nil
  end

  def known_role(name) when is_binary(name) do
    normalised = name |> String.trim() |> String.downcase() |> normalise_spelling()

    Enum.find_value(@role_names, fn {role, spelled} ->
      if normalise_spelling(String.downcase(spelled)) == normalised, do: role
    end)
  end

  # A role's name is spelled two ways in this project: the corpus spells it
  # as words ("Platform Admin") and a machine spells it as a token
  # ("platform_admin"). They are the same role, and a name that arrives from
  # a directory, a configuration file or a command line is far more likely to
  # be the token.
  #
  # Without this, an account created with the token spelling stores a role
  # the Principal cannot read, and the account holds no authority at all —
  # silently, because the role is simply not recognised.
  defp normalise_spelling(value), do: String.replace(value, "_", " ")

  @doc """
  Builds a Principal, normalising the roles it is given.

  Unknown roles are dropped. A Principal with no known role is still a
  Principal — it is a person the product can name — but it holds no
  authority, and the Policy will refuse everything it asks for.
  """
  @spec new(String.t(), String.t(), [String.t() | role()], keyword()) :: t()
  def new(id, workspace, roles \\ [], opts \\ [])

  def new(id, workspace, roles, opts) when is_binary(id) and is_binary(workspace) do
    %__MODULE__{
      id: id,
      workspace: workspace,
      roles:
        roles |> List.wrap() |> Enum.map(&known_role/1) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      kind: known_kind(Keyword.get(opts, :kind, :human)),
      display_name: Keyword.get(opts, :display_name)
    }
  end

  # The kind arrives as an atom from the code and as a string from the store
  # — the store holds what the corpus calls it.
  defp known_kind(kind) when kind in [:human, :agentic, :service, :system], do: kind

  defp known_kind(kind) when is_binary(kind) do
    case kind do
      "human" -> :human
      "agentic" -> :agentic
      "service" -> :service
      "system" -> :system
      _ -> :human
    end
  end

  defp known_kind(_kind), do: :human

  @doc """
  The corpus's spelling of a Principal's roles, as the store carries them.
  """
  @spec role_strings(t()) :: [String.t()]
  def role_strings(%__MODULE__{roles: roles}) do
    Enum.map(roles, fn role -> Map.fetch!(@role_names, role) end)
  end

  @doc """
  Whether the Principal holds a role.
  """
  @spec role?(t(), role()) :: boolean()
  def role?(%__MODULE__{roles: roles}, role), do: role in roles

  @doc """
  The actor this Principal is recorded as in the Audit Log.

  The kind becomes the actor's type, so the Log says *what* acted and not
  only who. An Agentic Actor's entries therefore cannot be confused with a
  person's.
  """
  @spec audit_actor(t()) :: %{type: String.t(), id: String.t()}
  def audit_actor(%__MODULE__{kind: :human} = principal), do: %{type: "user", id: principal.id}

  def audit_actor(%__MODULE__{kind: :agentic} = principal),
    do: %{type: "agentic_actor", id: principal.id}

  def audit_actor(%__MODULE__{kind: :service} = principal),
    do: %{type: "service", id: principal.id}

  def audit_actor(%__MODULE__{kind: :system} = principal), do: %{type: "system", id: principal.id}
end
