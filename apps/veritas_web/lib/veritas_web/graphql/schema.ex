defmodule Veritas.Web.GraphQL.Schema do
  @moduledoc """
  The GraphQL surface.

  Absinthe is the second of the three surfaces over one service layer (INV-8):
  the LiveView UI, this GraphQL API and the CLI all call `Veritas.Core`, and
  none of them talks to the datastore directly. That is what makes "every
  operation available in the UI is available in GraphQL and the CLI" a
  property of the code rather than a promise.

  ## Errors are binaries

  A resolver hands Absinthe a **binary**, never an error struct. Absinthe's
  error formatter calls `String.Chars.to_string/1` on whatever a resolver
  returns, and `Veritas.Store.Error` does not implement that protocol: handing
  the struct back raised `Protocol.UndefinedError` inside the formatter, so
  every store fault became an HTTP 500 with a debug page carrying the raw
  engine error body, the internal namespace name and the request parameters.
  `Veritas.Store.Error.message/1` already renders every shape the domain and
  the store can produce, so the surface uses it rather than a second
  formatter.

  ## Cost

  The list fields declare a **complexity**, and the API is capped by
  `max_complexity` and `token_limit` (see `config/config.exs`). A request is
  charged for the rows it may return, so a client cannot multiply one query
  into thousands of rows by aliasing it, and a client cannot ask for the whole
  CMDB in one request.
  """
  use Absinthe.Schema
  import_types(Veritas.Web.GraphQL.WorkflowTypes)

  alias Veritas.Core.{Audit, CI, Policy, Principal, Tickets}
  alias Veritas.Store.Error

  # The number of rows a list field returns when the caller does not say.
  # It is the domain's own default; the store caps a list at 1_000.
  @default_list_limit 50
  @store_list_limit 1_000

  # The flat cost of a CI type registry, which is seeded and small.
  @ci_type_cost 10

  # The flat cost of a blast-radius walk, which is a graph traversal rather
  # than a list.
  @impact_cost 200

  @desc "A free-form map: a CI's attributes, or a type's schema for them."
  scalar :json_map, name: "JsonMap" do
    serialize(& &1)

    parse(fn
      %{string: value} -> {:ok, value}
      value -> {:ok, value}
    end)
  end

  @desc "A ticket. The shared lifecycle lives here; the type-specific fields live in the per-type detail table."
  object :ticket do
    field(:id, :string)
    field(:workspace, :string)
    field(:ticket_type, :string)
    field(:state, :string)
    field(:title, :string)
    field(:description, :string)
    field(:priority, :string)
    field(:opened_at, :string)
  end

  @desc "A CI that depends on another, with the relation kind and the target it points at."
  object :impact_row do
    field(:dependent, :string)
    field(:relation_kind, :string)
    field(:target, :string)
  end

  @desc "A CI (Configuration Item) in the CMDB."
  object :ci do
    field(:id, :string)
    field(:ci_type, :string)
    field(:name, :string)
    field(:lifecycle_state, :string)
    field(:criticality, :string)
    field(:owner, :string)
    field(:attributes, :json_map)
  end

  @desc "A CI type: the registry that says what a CI of that type may carry."
  object :ci_type do
    field(:id, :string)
    field(:name, :string)
    field(:plural, :string)
    field(:required, list_of(:string))
    field(:schema, :json_map)
  end

  @desc "The blast radius of a CI: what depends on it, and what is affected."
  object :impact_result do
    field(:ci_id, :string)
    field(:dependents, list_of(:ci))
    field(:services, list_of(:ci))
    field(:tickets, list_of(:ticket))
  end

  @desc "The result of verifying the Audit Log chain for a workspace."
  object :audit_verification do
    field(:intact, :boolean)
    field(:first_break_index, :integer)
  end

  query do
    import_fields(:workflow_queries)
    @desc "Tickets in a workspace, optionally filtered by type and state."
    field :tickets, list_of(:ticket) do
      arg(:workspace, non_null(:string))
      arg(:ticket_type, :string)
      arg(:state, :string)
      arg(:limit, :integer)
      complexity(fn args, child -> list_cost(args[:limit], child) end)
      resolve(&resolve_tickets/3)
    end

    @desc "One ticket by identifier."
    field :ticket, :ticket do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      resolve(&resolve_ticket/3)
    end

    @desc "The CIs of a workspace, optionally filtered by type, lifecycle state and criticality."
    field :cis, list_of(:ci) do
      arg(:workspace, non_null(:string))
      arg(:ci_type, :string)
      arg(:lifecycle_state, :string)
      arg(:criticality, :string)
      arg(:limit, :integer)
      complexity(fn args, child -> list_cost(args[:limit], child) end)
      resolve(&resolve_cis/3)
    end

    @desc "One CI by identifier."
    field :ci, :ci do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      resolve(&resolve_ci/3)
    end

    @desc "The registered CI types of a workspace."
    field :ci_types, list_of(:ci_type) do
      arg(:workspace, non_null(:string))
      complexity(fn _args, child -> @ci_type_cost * (child + 1) end)
      resolve(&resolve_ci_types/3)
    end

    @desc "The CIs that depend on a given CI — the question the CMDB exists to answer."
    field :impact, :impact_result do
      arg(:workspace, non_null(:string))
      arg(:ci_id, non_null(:string))
      arg(:depth, :integer)
      complexity(fn _args, child -> @impact_cost + child end)
      resolve(&resolve_impact/3)
    end

    @desc "Verifies the Audit Log chain for a workspace."
    field :audit_verification, :audit_verification do
      arg(:workspace, non_null(:string))
      resolve(&resolve_audit_verification/3)
    end
  end

  mutation do
    import_fields(:workflow_mutations)

    @desc "Creates a CI. The attributes are checked against its type's schema before anything is written."
    field :create_ci, :ci do
      arg(:workspace, non_null(:string))
      arg(:ci_type, non_null(:string))
      arg(:name, non_null(:string))
      arg(:lifecycle_state, :string)
      arg(:criticality, :string)
      arg(:owner, :string)
      arg(:attributes, :json_map)
      arg(:reason, :string)
      resolve(&resolve_create_ci/3)
    end

    @desc "Opens a ticket. The ticket, its detail row and its first audit entry are written in one transaction."
    field :open_ticket, :ticket do
      arg(:workspace, non_null(:string))
      arg(:ticket_type, non_null(:string))
      arg(:title, non_null(:string))
      arg(:requester, non_null(:string))
      arg(:description, :string)
      arg(:priority, :string)
      arg(:correlation_id, :string)
      resolve(&resolve_open_ticket/3)
    end

    @desc """
    Moves a ticket to a new state. An illegal transition is refused before
    anything is written.

    The actor is **the signed-in Principal**, not an argument. There is no
    `actorId`: a caller that could name the actor could act as somebody
    else, and the Audit Log would record the wrong name for the action.
    """
    field :transition_ticket, :ticket do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      arg(:to_state, non_null(:string))
      arg(:reason, :string)
      arg(:correlation_id, :string)
      resolve(&resolve_transition/3)
    end

    @desc """
    Updates a ticket's content: its title and its description.

    The content is the free text a person reads, and it is the only thing this
    mutation changes. The mutation carries the other ticket fields as
    arguments so that a caller **can** name one, and the domain refuses a
    field it does not own **by name** rather than having this surface drop it:
    a caller cannot come away believing it moved a ticket that did not move.
    The state belongs to the workflow and moves through `transitionTicket`.

    A field the caller did not send is not a change: it is not handed to the
    domain at all, so it cannot overwrite what the ticket already holds.

    An update that changes nothing is refused rather than accepted: an
    operation that changed nothing must not leave a record claiming that it
    did.

    The actor is **the signed-in Principal**, not an argument, for the same
    reason `transitionTicket` does it that way: a caller that could name the
    actor could act as somebody else, and the Audit Log would record the
    wrong name for the action.
    """
    field :update_ticket, :ticket do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      arg(:title, :string)
      arg(:description, :string)
      arg(:state, :string)
      arg(:priority, :string)
      arg(:requester, :string)
      resolve(&resolve_update/3)
    end
  end

  # ── resolvers ────────────────────────────────────────────────────────────
  #
  # Every resolver calls `guard/3` before it touches data. The guard is
  # `Veritas.Core.Policy`, the one deny-by-default check every surface calls
  # (`docs/09` §4); the Principal it decides about is the one the request
  # was signed in as. There is no second rulebook here.

  defp resolve_tickets(_parent, args, resolution) do
    opts =
      []
      |> maybe(:ticket_type, args[:ticket_type])
      |> maybe(:state, args[:state])
      |> maybe(:limit, args[:limit])

    with :ok <- guard(resolution, "ticket:read", %{workspace: args[:workspace]}),
         {:ok, rows} <- Tickets.list(args[:workspace], opts) do
      {:ok, Enum.map(rows, &to_ticket/1)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_ticket(_parent, args, resolution) do
    with :ok <- guard(resolution, "ticket:read", %{workspace: args[:workspace]}),
         {:ok, row} <- Tickets.read(args[:workspace], args[:id]) do
      {:ok, row && to_ticket(row)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_cis(_parent, args, resolution) do
    opts =
      []
      |> maybe(:ci_type, args[:ci_type])
      |> maybe(:lifecycle_state, args[:lifecycle_state])
      |> maybe(:criticality, args[:criticality])
      |> maybe(:limit, args[:limit])

    with :ok <- guard(resolution, "ci:read", %{workspace: args[:workspace]}),
         {:ok, rows} <- CI.list(args[:workspace], opts) do
      {:ok, Enum.map(rows, &to_ci/1)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_ci(_parent, args, resolution) do
    with :ok <- guard(resolution, "ci:read", %{workspace: args[:workspace]}),
         {:ok, row} <- CI.get(args[:workspace], args[:id]) do
      {:ok, row && to_ci(row)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_ci_types(_parent, args, resolution) do
    with :ok <- guard(resolution, "ci:read", %{workspace: args[:workspace]}),
         {:ok, rows} <- CI.types(args[:workspace]) do
      {:ok,
       Enum.map(rows, fn row ->
         %{
           id: row["id"],
           name: row["name"],
           plural: row["plural"],
           required: row["required"] || [],
           schema: row["schema"] || %{}
         }
       end)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_create_ci(_parent, args, resolution) do
    attrs = %{
      "ci_type" => args[:ci_type],
      "name" => args[:name],
      "lifecycle_state" => args[:lifecycle_state],
      "criticality" => args[:criticality],
      "owner" => args[:owner],
      "attributes" => args[:attributes] || %{},
      "reason" => args[:reason],
      "actor" => actor(resolution)
    }

    with :ok <- guard(resolution, "ci:write", %{workspace: args[:workspace]}),
         {:ok, row} <- CI.create(args[:workspace], attrs) do
      {:ok, to_ci(row)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_impact(_parent, args, resolution) do
    # `Veritas.Core.CI.impact/3` takes the depth as a positive integer
    # (`@spec impact(workspace(), String.t(), pos_integer())`), not as an
    # options list. A depth that is not a positive integer falls back to the
    # domain's own default rather than raising.
    depth = if is_integer(args[:depth]) and args[:depth] > 0, do: args[:depth], else: 2

    with :ok <- guard(resolution, "graph:query", %{workspace: args[:workspace]}),
         {:ok, result} <- CI.impact(args[:workspace], args[:ci_id], depth) do
      {:ok,
       %{
         ci_id: args[:ci_id],
         dependents: Enum.map(result[:dependents] || [], &to_ci/1),
         services: Enum.map(result[:services] || [], &to_ci/1),
         tickets: Enum.map(result[:tickets] || [], &to_ticket/1)
       }}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_audit_verification(_parent, args, resolution) do
    with :ok <- guard(resolution, "audit:read", %{workspace: args[:workspace]}),
         {:ok, verdict} <- Audit.verify(args[:workspace]) do
      case verdict do
        :intact -> {:ok, %{intact: true, first_break_index: nil}}
        {:broken_at, index} -> {:ok, %{intact: false, first_break_index: index}}
      end
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_open_ticket(_parent, args, resolution) do
    attrs = %{
      "title" => args[:title],
      "description" => args[:description] || "",
      "requester" => args[:requester],
      "priority" => args[:priority] || "medium"
    }

    with :ok <-
           guard(resolution, "ticket:write", %{
             workspace: args[:workspace],
             ticket_type: args[:ticket_type]
           }),
         {:ok, row} <-
           Tickets.open(
             args[:workspace],
             args[:ticket_type],
             attrs,
             actor(resolution),
             args[:correlation_id]
           ) do
      {:ok, to_ticket(row)}
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_transition(_parent, args, resolution) do
    opts =
      []
      |> maybe(:reason, args[:reason])
      |> maybe(:correlation_id, args[:correlation_id])

    with :ok <- guard(resolution, "ticket:read", %{workspace: args[:workspace]}),
         {:ok, row} <-
           Tickets.transition(
             args[:workspace],
             args[:id],
             args[:to_state],
             principal(resolution),
             opts
           ) do
      {:ok, to_ticket(row)}
    else
      {:error, :not_found} -> {:error, "the ticket does not exist"}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp resolve_update(_parent, args, resolution) do
    # The fields the caller named, and nothing else.
    #
    # A field that was not sent is absent from the argument map, so it is not
    # handed to the domain at all and cannot overwrite what the ticket
    # already holds. A field the caller **did** name is handed over even when
    # the domain does not own it: the domain refuses it by name, which is
    # better than this surface dropping it and leaving the caller believing
    # it was applied.
    attrs =
      args
      |> Map.take([:title, :description, :state, :priority, :requester])
      |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)

    # The ticket's type is what the role matrix is indexed by, so it is read
    # before the guard — and the read is itself guarded. Nothing is written
    # until the guard has said yes.
    with :ok <- guard(resolution, "ticket:read", %{workspace: args[:workspace]}),
         {:ok, ticket} <- Tickets.read(args[:workspace], args[:id]),
         false <- is_nil(ticket),
         :ok <-
           guard(resolution, "ticket:write", %{
             workspace: args[:workspace],
             ticket_type: ticket["ticket_type"]
           }),
         {:ok, row} <- Tickets.update(args[:workspace], args[:id], attrs, actor(resolution)) do
      {:ok, to_ticket(row)}
    else
      {:error, reason} -> {:error, error(reason)}
      true -> {:error, "the ticket does not exist"}
    end
  end

  # The guard: the one deny-by-default check. A refusal is an error the
  # client can read, and it has already been written to the Audit Log by the
  # Policy itself.
  defp guard(resolution, capability, context) do
    case Policy.authorize(principal(resolution), capability, context) do
      :allow -> :ok
      {:deny, reason} -> {:error, reason}
    end
  end

  defp principal(%{context: context}), do: context[:principal]
  defp principal(_resolution), do: nil

  # The actor is the signed-in Principal. There is no way for a caller to
  # name somebody else.
  defp actor(resolution) do
    case principal(resolution) do
      %Principal{} = principal -> Principal.audit_actor(principal)
      _ -> %{type: "unknown", id: "unknown"}
    end
  end

  defp to_ticket(row) do
    %{
      id: row["id"],
      workspace: row["workspace"],
      ticket_type: row["ticket_type"],
      state: row["state"],
      title: row["title"],
      description: row["description"],
      priority: row["priority"],
      opened_at: row["opened_at"] && to_string(row["opened_at"])
    }
  end

  defp to_ci(row) do
    %{
      id: row["id"],
      ci_type: row["ci_type"],
      name: row["name"],
      lifecycle_state: row["lifecycle_state"],
      criticality: row["criticality"],
      owner: row["owner"],
      attributes: row["attributes"] || %{}
    }
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)

  # The error a resolver hands back is a **binary**. Absinthe's error
  # formatter calls `String.Chars.to_string/1` on it, and
  # `Veritas.Store.Error` does not implement that protocol — handing the
  # struct back raised `Protocol.UndefinedError` and turned every store
  # fault into an HTTP 500 with a debug page. `Error.message/1` already
  # renders every shape the domain and the store can produce, so the surface
  # uses it rather than a second formatter: a refusal the domain **named**
  # reads in the same words here as it does in the CLI and on a screen.
  defp error(reason), do: Error.message(reason) || "the operation could not be completed"

  # The cost of a list field is the number of rows it may return, times the
  # cost of one row. The store caps a list at 1_000 rows, so a request for
  # more is charged for what the store would actually do rather than for
  # what the caller asked for.
  defp list_cost(limit, child) do
    rows = (limit || @default_list_limit) |> min(@store_list_limit)
    rows * (child + 1)
  end
end
