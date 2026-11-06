defmodule Veritas.Core.Policy do
  @moduledoc """
  The authorisation decision point.

  `docs/09` §4 says it plainly: Veritas uses *"RBAC for who you are and
  relationship rules for what you may touch, resolved by one deny-by-default
  check that every entry point calls"*, and the enforcement table names the
  same check for every surface — `(principal, action, resource, context)`.

  This module **is** that check. It is a plain module: no behaviour, no
  configuration, no adapter. Every surface — the GraphQL resolvers, the
  LiveView mount and event handlers — calls `authorize/3` and nothing else
  decides authority. A surface that wanted to ask "may this principal read
  tickets?" anywhere but here would be a second rulebook, and the corpus's
  whole point is that there is one.

  ## The rules are the corpus's, not this module's

  The role set and the per-ticket-type R/A/C/I matrix are `docs/02`
  §Role matrix, transcribed. `docs/09` §4 is explicit that those hard rules
  — *"not a generic permission list"* — are the normative definition, and
  that `docs/02` is normative over `docs/08` where the two disagree.

  So the authority a role has over a ticket type is read off the matrix:

    * **R** (responsible) and **A** (accountable) mean the role may act on
      that ticket type.
    * **C** (consulted) and **I** (informed) mean the role may read it.
      Reading is therefore open to every role in the vocabulary, which is
      what the matrix says; writing is not.

  The hard rules that sit beside the matrix are enforced as the exceptions
  they are:

    * a **Requester** may withdraw their own Service Request and **never
      authorises** anything;
    * an **Agentic Actor** holds no R and no A anywhere, so its output is a
      proposal;
    * **Platform Admin** and **Auditor** hold no transition rights.

  ## Deny by default

  The default answer is "no". A capability that is not in the closed
  vocabulary, a role that is not in the `docs/02` set, a check with no
  Workspace context, a Workspace that is not the Principal's own, and a
  ticket type the caller did not name are all refusals — not permissions
  that were forgotten to be listed.

  ## Denials are recorded

  `docs/09` §4: *"Denials are recorded, not silently swallowed — a denied
  read is a detection signal."* So `authorize/3` writes the refusal to the
  Audit Log, in the Workspace the Principal acts in, before it returns it.
  A denial is therefore evidence in the chain, not a gap in it.

  The Audit Log write cannot change the answer: if the store is unreachable
  the refusal is still a refusal, and the failure to record it is logged
  rather than raised. A record that cannot be written must never become a
  permission.
  """

  require Logger

  alias Veritas.Core.{Audit, Principal, WorkspaceLock}
  alias Veritas.Store.Error

  @typedoc """
  The context of a check: what the action is about.

  `:workspace` is always required. `:ticket_type` is required for the
  ticket capabilities. The remaining keys are the relationship facts
  `docs/09` §4 and `docs/02` §Separation of duty ask for, and they are
  honoured when the caller supplies them.
  """
  @type context :: %{
          required(:workspace) => String.t(),
          optional(:ticket_type) => String.t() | atom(),
          optional(:requester) => String.t(),
          optional(:requester_id) => String.t(),
          optional(:author_id) => String.t(),
          optional(:implementer_id) => String.t(),
          optional(:sole_implementer) => boolean(),
          optional(:ci_owner_id) => String.t(),
          optional(:to_state) => String.t(),
          optional(:correlation_id) => String.t()
        }

  @typedoc "The capability being asked for, from the closed vocabulary."
  @type capability :: String.t() | atom()

  @typedoc "The verdict."
  @type verdict :: :allow | {:deny, String.t()}

  # ── the capability vocabulary ──────────────────────────────────────────────
  #
  # `docs/08` §Capabilities is a *closed* vocabulary, and `docs/09` §3 says
  # an API token carries a subset of it. The same names are used here, so a
  # human's authority and a token's scope are the same question asked in the
  # same words.
  #
  # Only the capabilities a **person** can hold are listed as grantable. The
  # remaining names in the `docs/08` vocabulary are Plugin and agent
  # capabilities: the host re-validates a Plugin's grant at its own host API
  # on every call (`docs/09` §4), and a person does not hold them by virtue
  # of their role. They are refused here.

  @capabilities %{
    "ci:read" => :ci_read,
    "ci:write" => :ci_write,
    "delivery:read" => :delivery_read,
    "delivery:write" => :delivery_write,
    "ticket:read" => :ticket_read,
    "ticket:write" => :ticket_write,
    "ticket:transition" => :ticket_transition,
    "graph:query" => :graph_query,
    "audit:read" => :audit_read,
    "secret:read" => :secret_read,
    "plugin:read" => :plugin_read,
    "account:administrate" => :account_administrate
  }

  # ── the role matrix ────────────────────────────────────────────────────────
  #
  # `docs/02` §Roles and RACI, transcribed. The columns are the five ticket
  # types; the letters are the matrix's own.
  #
  #   R responsible · A accountable · C consulted · I informed
  #
  # A role acts on a ticket type when it holds R or A there. It may read one
  # when it holds any of the four.

  @matrix %{
    requester: %{
      service_request: "R",
      incident: "C",
      change: "C",
      problem: "I",
      vulnerability: "C"
    },
    service_desk_agent: %{
      service_request: "R",
      incident: "R",
      change: "I",
      problem: "I",
      vulnerability: "I"
    },
    service_desk_manager: %{
      service_request: "A",
      incident: "C",
      change: "C",
      problem: "I",
      vulnerability: "I"
    },
    incident_manager: %{
      service_request: "I",
      incident: "A",
      change: "C",
      problem: "C",
      vulnerability: "I"
    },
    change_manager: %{
      service_request: "I",
      incident: "C",
      change: "R",
      problem: "C",
      vulnerability: "I"
    },
    cab_chair: %{
      service_request: "I",
      incident: "C",
      change: "A",
      problem: "C",
      vulnerability: "I"
    },
    cab_member: %{
      service_request: "I",
      incident: "C",
      change: "R",
      problem: "C",
      vulnerability: "I"
    },
    problem_manager: %{
      service_request: "I",
      incident: "C",
      change: "C",
      problem: "A",
      vulnerability: "C"
    },
    vulnerability_owner: %{
      service_request: "I",
      incident: "I",
      change: "C",
      problem: "C",
      vulnerability: "A"
    },
    ci_steward: %{
      service_request: "C",
      incident: "C",
      change: "C",
      problem: "C",
      vulnerability: "C"
    },
    agentic_actor: %{
      service_request: "C",
      incident: "C",
      change: "C",
      problem: "C",
      vulnerability: "C"
    },
    platform_admin: %{
      service_request: "I",
      incident: "I",
      change: "I",
      problem: "I",
      vulnerability: "I"
    },
    auditor: %{service_request: "I", incident: "I", change: "I", problem: "I", vulnerability: "I"}
  }

  # The ticket types the matrix has a column for.
  @ticket_types ~w(service_request incident change problem vulnerability)a

  # The environment variable an operator sets to choose the deployment
  # profile. It is one setting, and the operator changes it.
  @profile_var "VERITAS_DEPLOYMENT_PROFILE"

  # The states that are an **authorisation**: reaching one is a decision, and
  # `docs/02` §Separation of duty governs who may reach it.
  #
  # `accepted_risk` is a Vulnerability's risk acceptance and `closed` is a
  # Problem's closure; both are approvals in the corpus's sense, and both
  # carry the rule that the approver is distinct from the requester and the
  # implementer.
  @authorisation_states %{
    service_request: ["authorized", "rejected"],
    change: ["authorized", "rejected"],
    vulnerability: ["accepted_risk"],
    problem: ["closed"]
  }

  @doc """
  The closed capability vocabulary, as the names the corpus uses.
  """
  @spec capabilities() :: [String.t()]
  def capabilities, do: Map.keys(@capabilities)

  @doc """
  The matrix, as the corpus spells it.

  Exposed so that the decision point can be read rather than trusted: the
  table this module decides by is the table in `docs/02`.
  """
  @spec matrix() :: %{atom() => %{atom() => String.t()}}
  def matrix, do: @matrix

  @doc """
  The ticket types the matrix has a column for.
  """
  @spec ticket_types() :: [atom()]
  def ticket_types, do: @ticket_types

  @doc """
  Decides whether a Principal may do something.

  Returns `:allow` or `{:deny, reason}`. A denial is written to the Audit
  Log before it is returned. A domain operation already holding the workspace
  lock passes its transaction as the fourth argument and commits the denial
  without performing the refused mutation.
  """
  @spec authorize(Principal.t() | nil, capability(), context() | map(), Veritas.Store.tx() | nil) ::
          verdict()
  def authorize(principal, capability, context \\ %{}, tx \\ nil) do
    context = normalise_context(context)

    case decide(principal, capability, context) do
      :allow ->
        :allow

      {:deny, reason} ->
        record_denial(principal, capability, context, reason, tx)
        {:deny, reason}
    end
  end

  @doc """
  Decides without recording anything.

  The decision is the same one `authorize/3` makes; this one does not write
  to the Audit Log, and exists for the places that ask what the answer would
  be — a screen that greys a button, a CLI that prints a capability list.
  """
  @spec permitted?(Principal.t() | nil, capability(), context() | map()) :: boolean()
  def permitted?(principal, capability, context \\ %{}) do
    :allow == decide(principal, capability, normalise_context(context))
  end

  # ── the decision ───────────────────────────────────────────────────────────

  defp decide(nil, _capability, _context), do: {:deny, "the request carries no principal"}

  defp decide(%Principal{} = principal, capability, context) do
    # The Principal's own id travels with the context: the separation-of-duty
    # rules and the Requester's withdrawal rule are both about *whose* action
    # this is, and a rule that cannot see the actor cannot be applied.
    context = Map.put(context, :principal_id, principal.id)

    with {:ok, name} <- known_capability(capability),
         {:ok, workspace} <- workspace_context(context),
         {:ok, ticket_type} <- ticket_type_context(context, name),
         :ok <- same_workspace(principal, workspace),
         :ok <- separation_of_duty(principal, name, ticket_type, context) do
      if granted?(principal, name, context, ticket_type) do
        :allow
      else
        {:deny, denial_reason(principal, name, ticket_type)}
      end
    end
  end

  defp decide(_principal, _capability, _context),
    do: {:deny, "the request carries no principal"}

  defp known_capability(capability) do
    case Map.fetch(@capabilities, to_string(capability)) do
      {:ok, name} ->
        {:ok, name}

      :error ->
        {:deny, "the capability #{inspect(to_string(capability))} is not in the vocabulary"}
    end
  end

  # Every operation is Workspace-scoped (`docs/09` §5): the repository layer
  # refuses a query without a Workspace context, and so does this.
  defp workspace_context(context) do
    case Map.get(context, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        {:ok, workspace}

      _ ->
        {:deny, "the request carries no workspace context"}
    end
  end

  # The ticket type is what the R/A matrix is indexed by, so a ticket
  # capability asked without one cannot be decided and is refused.
  defp ticket_type_context(context, capability)
       when capability in [:ticket_write, :ticket_transition] do
    case Map.get(context, :ticket_type) do
      nil ->
        {:deny, "the request names no ticket type, so no role's authority over it can be read"}

      type ->
        {:ok, normalise_ticket_type(type)}
    end
  end

  defp ticket_type_context(_context, _capability), do: {:ok, nil}

  # The matrix is indexed by atom; a caller may name a ticket type as the
  # string the corpus uses — a GraphQL argument arrives that way.
  defp normalise_ticket_type(type) when is_atom(type), do: type

  defp normalise_ticket_type(type) when is_binary(type) do
    Enum.find(@ticket_types, fn known -> Atom.to_string(known) == type end) || type
  end

  defp same_workspace(%Principal{workspace: workspace}, workspace), do: :ok

  defp same_workspace(%Principal{workspace: principal_workspace}, workspace) do
    {:deny,
     "the principal acts in #{inspect(principal_workspace)} and the request asks about " <>
       "#{inspect(workspace)}"}
  end

  # ── the grants ─────────────────────────────────────────────────────────────

  defp granted?(%Principal{kind: :agentic}, :ticket_transition, _context, _ticket_type),
    do: false

  defp granted?(%Principal{roles: roles}, capability, context, ticket_type) do
    Enum.any?(roles, fn role -> grants?(role, capability, context, ticket_type) end)
  end

  @doc """
  The deployment profile in force: `:home_lab` or `:enterprise`.

  `docs/09` names the two profiles and says what each is for. It does **not**
  say how an operator selects one, so this reads it from the environment
  first — `VERITAS_DEPLOYMENT_PROFILE=home_lab` or `=enterprise` — and from
  the application configuration second, and defaults to the home-lab profile.

  The default is the **home lab**: it is the deployment a single operator
  runs, and the owner of the product chooses. It is one setting, and the
  operator changes it.

  ## What the profile changes

  The **enterprise** profile is the corpus's role matrix, exactly: a Platform
  Admin configures policy and holds no transition rights, and the separation
  of duty is enforced server-side.

  The **home-lab** profile is **additive**: the Platform Admin holds the union
  of what the working roles hold, so one operator can run the whole product.
  Nothing is reduced — the enterprise profile keeps the matrix it has, and
  the separation of duty is the same in both profiles, because the corpus
  states it without a profile exception and this does not make one of it.
  """
  @spec profile() :: :home_lab | :enterprise
  def profile do
    case Application.get_env(:veritas_core, :deployment_profile) ||
           System.get_env(@profile_var) do
      :enterprise -> :enterprise
      "enterprise" -> :enterprise
      _ -> :home_lab
    end
  end

  @doc """
  The profile's name, as the corpus writes it.
  """
  @spec profile_name() :: String.t()
  def profile_name do
    case profile() do
      :enterprise -> "enterprise"
      :home_lab -> "home lab"
    end
  end

  @doc """
  The matrix in force for the profile in force.

  The enterprise profile is `docs/02` §Roles, unchanged. The home-lab profile
  is that table with the Platform Admin's row widened to the union of what
  the working roles hold — so one operator can run the whole product.
  """
  @spec effective_matrix() :: %{atom() => %{atom() => String.t()}}
  def effective_matrix do
    case profile() do
      :enterprise ->
        @matrix

      :home_lab ->
        admin =
          @matrix
          |> Map.get(:platform_admin, %{})
          |> Map.merge(union_row())

        Map.put(@matrix, :platform_admin, admin)
    end
  end

  # The union of what the working roles hold, per ticket type: the strongest
  # letter any role holds there. A role that holds nothing but "I" — the
  # Auditor, the Agentic Actor — contributes nothing.
  defp union_row do
    Map.new(@ticket_types, fn ticket_type ->
      letters =
        @matrix
        |> Map.delete(:platform_admin)
        |> Map.values()
        |> Enum.map(&Map.get(&1, ticket_type))
        |> Enum.reject(&is_nil/1)

      letter =
        cond do
          "A" in letters -> "A"
          "R" in letters -> "R"
          true -> "I"
        end

      {ticket_type, letter}
    end)
  end

  @doc """
  The roles that hold a capability, in the corpus's own spelling.

  A screen that withholds an action says which role may perform it, and this
  is where the answer comes from.
  """
  @spec capability_roles(String.t()) :: [String.t()]
  def capability_roles(capability) do
    case known_capability(capability) do
      {:ok, name} ->
        effective_matrix()
        |> Map.keys()
        |> Enum.filter(&role_holds?(&1, name))
        |> Enum.map(&Principal.role_name/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp role_holds?(role, capability) do
    grants?(role, capability, %{}, nil)
  end

  # Reading is open to every role in the vocabulary: the matrix gives every
  # one of them at least "informed" on every ticket type, and the CMDB is
  # shared substrate rather than a private namespace (`docs/08` §Capabilities).
  defp grants?(_role, :ticket_read, _context, _ticket_type), do: true
  defp grants?(_role, :ci_read, _context, _ticket_type), do: true

  # Delivery records are read by anyone who may read them.
  defp grants?(_role, :delivery_read, _context, _ticket_type), do: true
  defp grants?(_role, :graph_query, _context, _ticket_type), do: true

  # Writing and moving need R or A on that ticket type.
  defp grants?(role, :ticket_write, _context, ticket_type), do: responsible?(role, ticket_type)

  defp grants?(role, :ticket_transition, context, ticket_type) do
    responsible?(role, ticket_type) and transition_allowed?(role, context, ticket_type)
  end

  # The CI Steward owns CI type and relationship quality and signs CI
  # updates (`docs/02` §Roles). No other role's hard rule names CI records,
  # so no other role writes them — except the Platform Admin in the home-lab
  # profile, who holds the union of what the working roles hold.
  defp grants?(role, :ci_write, _context, _ticket_type) do
    role == :ci_steward or home_lab_admin?(role)
  end

  # A Program, a Milestone and a Work Item are records somebody changes,
  # and the role matrix applies to them as it applies to a CI: the CI
  # Steward is the role the corpus gives write authority over
  # configuration-derived records, and Delivery is where a change to the
  # configuration is planned. Nobody else may write them — except the
  # Platform Admin in the home-lab profile.
  defp grants?(role, :delivery_write, _context, _ticket_type) do
    role == :ci_steward or home_lab_admin?(role)
  end

  # Administering the accounts of a Workspace is a configuration act, and
  # the role whose hard rule is *"Configures policy"* is the Platform
  # Admin (`docs/02` §Roles). It is the only role that holds it.
  #
  # Account administration is not a `docs/08` Plugin scope:
  # a Plugin is never given the power to mint identities (`docs/09` §6.6
  # forbids it outright), so there is no scope for it and there is no
  # Plugin that may hold it. It is here because a person may.
  defp grants?(:platform_admin, :account_administrate, _context, _ticket_type), do: true
  defp grants?(_role, :account_administrate, _context, _ticket_type), do: false

  # Inspecting plugin grants does not grant the authority to install or run code.
  defp grants?(role, :plugin_read, _context, _ticket_type),
    do: role in [:auditor, :platform_admin]

  # The Audit Log and the Restricted fields are the Auditor's and the
  # Platform Admin's (`docs/02` §Roles, `docs/09` §4). The third reader the
  # corpus names — the owning workflow's named approver — is not modelled
  # yet, and is reported as a gap rather than approximated.
  defp grants?(role, :audit_read, _context, _ticket_type), do: role in [:auditor, :platform_admin]

  defp grants?(role, :secret_read, _context, _ticket_type),
    do: role in [:auditor, :platform_admin]

  # Anything the vocabulary does not name is refused. That is the closed
  # vocabulary doing its work: a Plugin capability is not a person's
  # capability.
  defp grants?(_role, _capability, _context, _ticket_type), do: false

  # The Platform Admin in the home-lab profile holds what the working roles
  # hold; in the enterprise profile the matrix is the corpus's table and
  # nothing else.
  defp home_lab_admin?(role), do: role == :platform_admin and profile() == :home_lab

  # The same question about a person rather than a role.
  defp platform_admin_in_home_lab?(%Principal{roles: roles}),
    do: :platform_admin in roles and profile() == :home_lab

  @doc """
  The fact that must survive in the Audit Log about a permitted authorisation.

  In the **home-lab** profile the separation of duty does not bind the
  Platform Admin, so an authorisation they make on a record they raised is
  permitted — and the Audit Log has to say so, because "whose decision was
  this?" is a question the running system has to answer.

  Returns `nil` when there is nothing to record: the enterprise profile, a
  transition that is not an authorisation, or a principal the rule does not
  touch.
  """
  @spec authorisation_note(Principal.t(), map()) :: map() | nil
  def authorisation_note(principal, context) do
    context = normalise_context(context)

    case Map.get(context, :ticket_type) do
      nil ->
        nil

      ticket_type ->
        case authorisation_decision(principal, normalise_ticket_type(ticket_type), context) do
          {:permit, note} -> note
          {:refuse, _reason} -> nil
        end
    end
  end

  @doc """
  The deployment profile in force, as an authorisation event records it.

  Every authorisation decision is made under a profile, and the home-lab
  profile is the one where the separation of duty does not bind the Platform
  Admin. So the event says which profile was in force — the question "whose
  decision was this, and under what rule?" is answerable from the running
  system rather than from a memory of how the deployment was set up.

  Returns `nil` for a transition that is not an authorisation.
  """
  @spec profile_fact(String.t(), String.t()) :: map() | nil
  def profile_fact(ticket_type, to_state) do
    if authorising?(normalise_ticket_type(ticket_type), to_state) do
      %{"profile" => profile_name()}
    else
      nil
    end
  end

  # Does the role hold R or A on this ticket type?
  defp responsible?(role, ticket_type) do
    case Map.get(Map.get(effective_matrix(), role, %{}), ticket_type) do
      letter when letter in ["R", "A"] -> true
      _ -> false
    end
  end

  # The hard rules that sit beside the matrix.
  defp transition_allowed?(:requester, context, :service_request) do
    # "May withdraw own request; never authorises." A withdrawal is the
    # Service Request's move to `cancelled` (`docs/02` §Service Request).
    context[:requester] == context[:principal_id] and context[:to_state] == "cancelled"
  end

  defp transition_allowed?(_role, _context, _ticket_type), do: true

  # ── separation of duty ─────────────────────────────────────────────────────
  #
  # `docs/02` §Separation of duty, enforced server-side: no actor may
  # authorise a Change they authored, requested, or will implement alone; a
  # CAB member who owns the affected CI must abstain; a Vulnerability Owner
  # cannot accept their own remediation.
  #
  # The rules are expressed against the relationship facts the caller
  # supplies. A caller that does not supply them has not supplied the
  # evidence the rule needs, so the rule cannot be applied — which is why
  # the callers that authorise pass them.
  #
  # **The rule is the enterprise profile's.** In the home-lab profile it does
  # not bind the Platform Admin: a one-operator deployment has nobody else to
  # hold the other side of the separation, and the profile is the operator's
  # statement that they are running the product alone. The fact that the rule
  # did not bind is recorded in the Audit Log, so "whose decision was this?"
  # has an answer from the running system.

  defp separation_of_duty(principal, :ticket_transition, ticket_type, context) do
    case authorisation_decision(principal, ticket_type, context) do
      {:permit, _note} -> :ok
      {:refuse, reason} -> {:deny, reason}
    end
  end

  defp separation_of_duty(_principal, _capability, _ticket_type, _context), do: :ok

  # The fact that the separation of duty did not bind, and why.
  @home_lab_note %{
    "separation_of_duty" =>
      "not applied: the home-lab profile does not bind the Platform Admin, " <>
        "so one operator may authorise a record they raised"
  }

  # The reason names the rule it enforces, so a screen says *why* rather than
  # refusing mysteriously.
  @separation_rule "the separation of duty: the approver must be distinct from the requester, the author and the implementer"

  # One decision, two answers: whether the authorisation is permitted, and the
  # fact that has to survive in the Audit Log when it is. They cannot
  # disagree, because they are the same decision.
  defp authorisation_decision(principal, ticket_type, context) do
    if authorising?(ticket_type, context[:to_state]) do
      case conflict(principal, context) do
        nil ->
          {:permit, nil}

        reason ->
          if platform_admin_in_home_lab?(principal) do
            {:permit, @home_lab_note}
          else
            {:refuse, reason}
          end
      end
    else
      {:permit, nil}
    end
  end

  defp conflict(principal, context) do
    cond do
      context[:author_id] == principal.id ->
        "#{@separation_rule} — the principal authored this record and may not authorise it"

      context[:requester_id] == principal.id ->
        "#{@separation_rule} — the principal requested this record and may not authorise it"

      context[:implementer_id] == principal.id and context[:sole_implementer] == true ->
        "#{@separation_rule} — the principal is the sole implementer and may not also authorise it"

      context[:ci_owner_id] == principal.id ->
        "#{@separation_rule} — the principal owns the affected CI and must abstain from the decision"

      true ->
        nil
    end
  end

  defp authorising?(ticket_type, to_state) when is_binary(to_state) do
    to_state in Map.get(@authorisation_states, ticket_type, [])
  end

  defp authorising?(_ticket_type, _to_state), do: false

  # ── the reason a denial carries ────────────────────────────────────────────

  defp denial_reason(%Principal{roles: roles}, capability, ticket_type) do
    case roles do
      [] ->
        "the principal holds no role in the vocabulary"

      roles ->
        "the role matrix (docs/02 §Roles) — the role#{if length(roles) == 1, do: "", else: "s"} " <>
          "#{Enum.map_join(roles, ", ", &inspect/1)} " <>
          "#{if length(roles) == 1, do: "does", else: "do"} not hold authority for " <>
          "#{capability_label(capability, ticket_type)}"
    end
  end

  defp capability_label(:ticket_write, ticket_type), do: "writing #{ticket_type} records"
  defp capability_label(:ticket_transition, ticket_type), do: "moving #{ticket_type} records"
  defp capability_label(:ticket_read, _ticket_type), do: "reading tickets"
  defp capability_label(:ci_write, _ticket_type), do: "writing CI records"
  defp capability_label(:ci_read, _ticket_type), do: "reading CI records"
  defp capability_label(:graph_query, _ticket_type), do: "querying the graph"
  defp capability_label(:audit_read, _ticket_type), do: "reading the Audit Log"
  defp capability_label(:secret_read, _ticket_type), do: "reading restricted fields"
  defp capability_label(:plugin_read, _ticket_type), do: "inspecting plugins"
  defp capability_label(:account_administrate, _ticket_type), do: "administering accounts"
  defp capability_label(capability, _ticket_type), do: to_string(capability)

  # ── recording the denial ───────────────────────────────────────────────────

  # A request that carries **no principal** is refused and the refusal is
  # recorded, under an actor nobody can attribute: `%{type: "unknown",
  # id: "unknown"}` — the shape the core already uses for a refused sign-in
  # (`Veritas.Core.Session.record_refusal/3`) and the shape the web layer's
  # own `actor/1` helper uses. The core does not depend on the web layer,
  # so the core's own convention is the one that is used here.
  #
  # The principal is matched **in the body**, not at the clause head. A guard
  # that fails at a head raises at the call site, and the `rescue` below —
  # which is in the body — never runs: a request with no principal crashed
  # `authorize/3` instead of being refused.
  defp record_denial(principal, capability, context, reason, tx) do
    event = %{
      subject: subject_of(principal),
      subject_table: "principal",
      from_state: nil,
      to_state: "refused",
      actor: actor_of(principal),
      reason: reason,
      correlation_id: context[:correlation_id],
      diff:
        %{
          "capability" => to_string(capability),
          "workspace" => context[:workspace],
          "ticket_type" => context[:ticket_type]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }

    case denial_transaction(context[:workspace], tx, fn tx ->
           Audit.append(tx, context[:workspace], event)
         end) do
      {:ok, _sequence} ->
        :ok

      {:error, reason} ->
        # The refusal stands. A Log that cannot be written is a fault in the
        # Log, and it must never turn into a permission.
        Logger.error(
          "[veritas.policy] a denial could not be recorded in the Audit Log: " <>
            (Error.message(reason) || inspect(reason))
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "[veritas.policy] a denial could not be recorded in the Audit Log: " <>
          Exception.message(error)
      )

      :ok
  end

  # The actor a denial is attributed to. A principal says who; a request with
  # nobody to name says so plainly.
  defp actor_of(%Principal{} = principal), do: Principal.audit_actor(principal)
  defp actor_of(_principal), do: %{type: "unknown", id: "unknown"}

  # The subject a denial is about: the principal, or nobody.
  defp subject_of(%Principal{} = principal), do: principal.id
  defp subject_of(_principal), do: "unknown"

  # The transaction that writes the denial, under the Workspace's lock — so
  # the chain has one writer at a time.
  #
  # A denial with **no Workspace** has nothing to lock and nowhere to write.
  # There the transaction is attempted as it was before the lock existed, so
  # its own refusal — the same message, the same rescue — is what the caller
  # sees. The lock must never turn "there is no Workspace to write to" into
  # something the caller cannot recognise.
  defp denial_transaction(workspace, nil, fun) when is_binary(workspace) do
    WorkspaceLock.with_lock(workspace, fn -> Veritas.Store.transaction(workspace, fun) end)
  end

  defp denial_transaction(workspace, nil, fun), do: Veritas.Store.transaction(workspace, fun)
  defp denial_transaction(_workspace, tx, fun), do: fun.(tx)

  # ── context ────────────────────────────────────────────────────────────────

  # The context's keys are atoms, but a caller may hand them over as strings
  # — a GraphQL argument arrives that way. Normalising here means the rest of
  # the module reads one shape.
  #
  # Only the keys this module knows are translated. A key that is not on the
  # list is dropped rather than turned into an atom: an atom is never
  # collected, and a context that arrives from a request must not be able to
  # make the host grow one.
  @context_keys ~w(workspace ticket_type requester requester_id author_id implementer_id
                   sole_implementer ci_owner_id to_state correlation_id)a

  defp normalise_context(context) when is_map(context) do
    Enum.reduce(context, %{}, fn {key, value}, acc ->
      case context_key(key) do
        nil -> acc
        atom -> Map.put(acc, atom, value)
      end
    end)
  end

  defp normalise_context(_context), do: %{}

  defp context_key(key) when is_atom(key) do
    if key in @context_keys, do: key, else: nil
  end

  defp context_key(key) when is_binary(key) do
    Enum.find(@context_keys, fn known -> Atom.to_string(known) == key end)
  end

  defp context_key(_key), do: nil
end
