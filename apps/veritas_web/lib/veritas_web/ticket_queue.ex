defmodule Veritas.Web.TicketQueue do
  @moduledoc """
  The ticket queues, and which one a route names.

  The product has five ticket types and four queues. A queue is the set of
  ticket types a screen shows together, and the **route** decides which set:

      /incidents        Incidents and Problems
      /requests         Service Requests
      /changes          Changes
      /vulnerabilities  Vulnerabilities

  ## The route decides, not the query string

  A queue is not a view parameter. The Workspace is the Principal's and the
  ticket type is the route's, and neither may be carried in a link. A request
  for `/requests?type=change` is answered with the Service Desk queue,
  because the route named it and the query string did not.

  The one thing a query string may carry is a **filter**, and a filter may
  only narrow the queue the route named: `?filter=problem` on the Incidents
  queue narrows it to Problems. A filter the queue does not have is not
  honoured — it falls back to the queue's own view of itself.

  ## Problems are a filter over the Incidents queue

  `docs/04` puts Problems in the Incidents queue: a Problem is an Incident
  with a linked root cause, so it is a narrower view of the same rows rather
  than a screen of its own. The queue therefore lists both types and the
  tabs narrow it.
  """

  alias Veritas.Core.Tickets

  @queues %{
    incidents: %{
      label: "Incidents",
      icon: "hero-exclamation-triangle",
      path: "/incidents",
      types: ["incident", "problem"],
      filters: [{"all", "All"}, {"incident", "Incidents"}, {"problem", "Problems"}]
    },
    service_request: %{
      label: "Service Desk",
      icon: "hero-inbox",
      path: "/requests",
      types: ["service_request"],
      filters: [{"all", "All"}]
    },
    change: %{
      label: "Changes",
      icon: "hero-calendar-days",
      path: "/changes",
      types: ["change"],
      filters: [{"all", "All"}]
    },
    vulnerability: %{
      label: "Security",
      icon: "hero-shield-check",
      path: "/vulnerabilities",
      types: ["vulnerability"],
      filters: [{"all", "All"}]
    }
  }

  @doc """
  The queue a route names.

  `nil` when the route names none, so a caller falls back rather than
  rendering an empty screen that pretends to be a queue.
  """
  @spec fetch(atom() | nil) :: map() | nil
  def fetch(live_action) when is_atom(live_action), do: Map.get(@queues, live_action)
  def fetch(_live_action), do: nil

  @doc """
  The queues, as the navigation sees them.
  """
  @spec all() :: %{atom() => map()}
  def all, do: @queues

  @doc """
  The filter a request asked for, narrowed to the ones the queue has.

  A filter the queue does not have is not honoured: it falls back to the
  queue's own view of itself, so a link carrying another queue's filter
  cannot change what the screen shows.
  """
  @spec selected_filter(map(), map()) :: String.t()
  def selected_filter(queue, params) do
    requested = params["filter"]
    allowed = Enum.map(queue.filters, &elem(&1, 0))

    if requested in allowed, do: requested, else: "all"
  end

  @doc """
  The tickets of a queue, newest first.

  One list call per ticket type the queue holds: a queue is a fixed set of
  types, so this is a fixed number of calls and never one per row.
  """
  @spec load(String.t(), map(), String.t()) :: [map()]
  def load(workspace, queue, filter) do
    queue.types
    |> Enum.filter(fn type -> filter == "all" or type == filter end)
    |> Enum.flat_map(fn type ->
      case Tickets.list(workspace, ticket_type: type, limit: 50) do
        {:ok, rows} -> rows
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&opened_at/1, :desc)
    |> Enum.take(50)
  end

  @doc """
  The path of a queue, with the filter it carries.

  The filter travels in the query string because it is a *narrowing* of the
  route's queue, not a choice of queue.
  """
  @spec path(map(), String.t()) :: String.t()
  def path(queue, "all"), do: queue.path
  def path(queue, filter), do: "#{queue.path}?filter=#{filter}"

  @doc """
  The queue a ticket type belongs to.

  A Problem belongs to the Incidents queue, because `docs/04` puts it there.
  """
  @spec path_for_type(String.t() | nil) :: String.t()
  def path_for_type("service_request"), do: "/requests"
  def path_for_type("change"), do: "/changes"
  def path_for_type("vulnerability"), do: "/vulnerabilities"
  def path_for_type(_type), do: "/incidents"

  @doc """
  The queue a ticket type belongs to, whole.
  """
  @spec queue_for_type(String.t() | nil) :: map()
  def queue_for_type(ticket_type) do
    path = path_for_type(ticket_type)

    Enum.find_value(@queues, fn {_key, queue} -> if queue.path == path, do: queue end)
  end

  defp opened_at(ticket) do
    case ticket["opened_at"] do
      %DateTime{} = at -> DateTime.to_iso8601(at)
      %NaiveDateTime{} = at -> NaiveDateTime.to_iso8601(at)
      at when is_binary(at) -> at
      _ -> ""
    end
  end
end
