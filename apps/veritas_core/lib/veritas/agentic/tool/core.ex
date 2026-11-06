defmodule Veritas.Agentic.Tool.Core do
  @moduledoc """
  The product's own capabilities, as tools.

  **Exactly the nine tool names `docs/08` names** — no additions
  (`docs/39` §6.2). The internal agent's core tool set and the MCP server's
  tool set are the same nine, projected from the same specs, so an external
  agent's action and an internal agent's action are indistinguishable for
  audit.

  ## Every handler calls the same choke point a person calls

  A tool handler calls `Veritas.Core.CI` or `Veritas.Core.Tickets` — the same
  modules the LiveView and the CLI call — so the agent's answers are a
  person's answers. No handler reaches the store adapter, and no handler
  makes a decision the domain would refuse.

  ## Read and write are separated

  `docs/08`: *"read tools and write tools are separated: `query_cmdb` and
  `search_ci` are read-only; `transition_incident` and `propose_change`
  require an approved Agent Run."* So the four read tools ask for nothing,
  and the three write tools ask every time.
  """

  alias Veritas.Agentic.Tool.{Registry, Spec}
  alias Veritas.Core.{CI, Principal, Tickets}

  @doc """
  Registers the nine core tools.

  Called by the application's start-up, so the Tools screen has real data
  before any provider is configured.
  """
  @spec register() :: :ok
  def register do
    Enum.each(specs(), &Registry.register(&1, source: :core))
  end

  @doc """
  The nine core tools.
  """
  @spec specs() :: [Spec.t()]
  def specs do
    [
      search_ci(),
      get_ci(),
      list_ci_relations(),
      query_cmdb(),
      list_incidents(),
      get_incident(),
      transition_incident(),
      create_service_request(),
      propose_change()
    ]
  end

  # ── the read tools ──────────────────────────────────────────────────────────

  defp search_ci do
    %Spec{
      name: "search_ci",
      description:
        "Find Configuration Items in the Workspace by type, lifecycle state or criticality.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "ci_type" => %{"type" => "string"},
          "lifecycle_state" => %{"type" => "string"},
          "criticality" => %{"type" => "string"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
        }
      },
      scope: ["ci:read"],
      side_effect: :read,
      approval: :never,
      timeout_ms: 10_000,
      idempotent: true,
      handler: fn arguments, context ->
        opts =
          [
            ci_type: arguments["ci_type"],
            lifecycle_state: arguments["lifecycle_state"],
            criticality: arguments["criticality"],
            limit: limit(arguments)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        CI.list(workspace(context), opts)
      end
    }
  end

  defp get_ci do
    %Spec{
      name: "get_ci",
      description: "One Configuration Item, by its id.",
      parameters: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      },
      scope: ["ci:read"],
      side_effect: :read,
      approval: :never,
      timeout_ms: 10_000,
      idempotent: true,
      handler: fn arguments, context ->
        with {:ok, id} <- required(arguments, "id") do
          CI.get(workspace(context), id)
        end
      end
    }
  end

  defp list_ci_relations do
    %Spec{
      name: "list_ci_relations",
      description: "The CIs related to a Configuration Item, in both directions.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "direction" => %{"type" => "string", "enum" => ["in", "out", "both"]},
          "depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
        },
        "required" => ["id"]
      },
      scope: ["ci:read"],
      side_effect: :read,
      approval: :never,
      timeout_ms: 10_000,
      idempotent: true,
      handler: fn arguments, context ->
        with {:ok, id} <- required(arguments, "id") do
          CI.relations(workspace(context), id, direction(arguments), depth(arguments))
        end
      end
    }
  end

  defp query_cmdb do
    %Spec{
      name: "query_cmdb",
      description: "The CMDB, and what depends on what: a CI, its relations and its impact.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
        },
        "required" => ["id"]
      },
      scope: ["ci:read"],
      side_effect: :read,
      approval: :never,
      timeout_ms: 15_000,
      idempotent: true,
      handler: fn arguments, context ->
        with {:ok, id} <- required(arguments, "id") do
          CI.impact(workspace(context), id, depth(arguments))
        end
      end
    }
  end

  defp list_incidents do
    %Spec{
      name: "list_incidents",
      description: "The tickets of the Workspace, optionally of one type.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "ticket_type" => %{"type" => "string"},
          "state" => %{"type" => "string"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
        }
      },
      scope: ["ticket:read"],
      side_effect: :read,
      approval: :never,
      timeout_ms: 10_000,
      idempotent: true,
      handler: fn arguments, context ->
        opts =
          [
            ticket_type: arguments["ticket_type"],
            state: arguments["state"],
            limit: limit(arguments)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        Tickets.list(workspace(context), opts)
      end
    }
  end

  defp get_incident do
    %Spec{
      name: "get_incident",
      description: "One ticket, by its id.",
      parameters: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      },
      scope: ["ticket:read"],
      side_effect: :read,
      approval: :never,
      timeout_ms: 10_000,
      idempotent: true,
      handler: fn arguments, context ->
        with {:ok, id} <- required(arguments, "id") do
          Tickets.read(workspace(context), id)
        end
      end
    }
  end

  # ── the write tools ─────────────────────────────────────────────────────────

  defp transition_incident do
    %Spec{
      name: "transition_incident",
      description: "Move a ticket to another state. Requires an approved Agent Run.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "to_state" => %{"type" => "string"}
        },
        "required" => ["id", "to_state"]
      },
      scope: ["ticket:transition"],
      side_effect: :write,
      approval: :always,
      timeout_ms: 10_000,
      idempotent: false,
      handler: fn arguments, _context ->
        with {:ok, _id} <- required(arguments, "id"),
             {:ok, _to_state} <- required(arguments, "to_state") do
          # Write execution stays closed until the approved-run path exists.
          {:error, :approval_required}
        end
      end
    }
  end

  defp create_service_request do
    %Spec{
      name: "create_service_request",
      description: "Raise a Service Request. Requires an approved Agent Run.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "requester" => %{"type" => "string"}
        },
        "required" => ["title"]
      },
      scope: ["ticket:write"],
      side_effect: :write,
      approval: :always,
      timeout_ms: 10_000,
      idempotent: false,
      handler: fn arguments, context ->
        Tickets.open(
          workspace(context),
          "service_request",
          %{
            "title" => arguments["title"],
            "description" => arguments["description"] || "",
            "requester" => arguments["requester"] || "unknown"
          },
          actor(context)
        )
      end
    }
  end

  defp propose_change do
    %Spec{
      name: "propose_change",
      description: "Propose a Change. Requires an approved Agent Run.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "requester" => %{"type" => "string"}
        },
        "required" => ["title"]
      },
      scope: ["ticket:write"],
      side_effect: :write,
      approval: :always,
      timeout_ms: 10_000,
      idempotent: false,
      handler: fn arguments, context ->
        Tickets.open(
          workspace(context),
          "change",
          %{
            "title" => arguments["title"],
            "description" => arguments["description"] || "",
            "requester" => arguments["requester"] || "unknown"
          },
          actor(context)
        )
      end
    }
  end

  # ── the small helpers ───────────────────────────────────────────────────────

  defp workspace(context), do: Map.get(context, :workspace)

  defp actor(context) do
    case Map.get(context, :actor) do
      %Principal{} = principal -> Principal.audit_actor(principal)
      _ -> %{type: "agentic_actor", id: "unknown"}
    end
  end

  defp required(arguments, key) do
    case arguments[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_arguments, "the argument #{inspect(key)} is required"}}
    end
  end

  defp limit(arguments), do: arguments["limit"] || 50

  defp depth(arguments), do: arguments["depth"] || 2

  defp direction(arguments) do
    case arguments["direction"] do
      "in" -> :in
      "out" -> :out
      _ -> :both
    end
  end
end
