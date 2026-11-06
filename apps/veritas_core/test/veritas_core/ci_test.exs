defmodule Veritas.Core.CITest do
  @moduledoc """
  The CMDB contract, from `docs/07` and `docs/32`.

  The CMDB is the substrate the rest of the product is built on: if a CI can
  hold attributes its type forbids, or a relation can join the wrong tables,
  then every graph query built on top of it is answering a question nobody
  asked.

  These tests are written against the corpus, not against the implementation:
  the `ci_type` registry is **data** (`docs/07`), the rules that bind a CI to
  its type are the product's, and the traversal is **bounded** (`docs/32`).
  Each one would fail if the implementation were wrong, and each one says
  what the corpus says it should be.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.CI

  @server_type %{
    "id" => "server",
    "name" => "Server",
    "plural" => "servers",
    "required" => ["region"],
    "schema" => %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string"},
        "cores" => %{"type" => "integer"},
        "rack_unit" => %{"type" => "string"}
      }
    }
  }

  @runs_on_kind %{
    "id" => "runs_on",
    "label" => "runs on",
    "from_table" => "ci",
    "to_table" => "ci",
    "inverse" => "hosts"
  }

  describe "the ci_type registry is data" do
    test "a CI of an unregistered type is refused, and nothing is written", %{
      workspace: workspace
    } do
      # Not "server": the migration seeds the standard vocabulary, so that type
      # IS registered. The point is a type nobody registered.
      assert {:error, reason} =
               CI.create(workspace, %{"ci_type" => "not_a_registered_type", "name" => "web-01"})

      assert reason =~ "not_a_registered_type",
             "the refusal must name the type it could not find"

      assert {:ok, []} = CI.list(workspace)
    end

    test "a type registered at runtime works immediately, with no code change", %{
      workspace: workspace
    } do
      assert {:ok, _type} = CI.register_type(workspace, @server_type)

      assert {:ok, ci} =
               CI.create(workspace, %{
                 "ci_type" => "server",
                 "name" => "web-01",
                 "attributes" => %{"region" => "eu-west-1", "cores" => 8}
               })

      assert ci["ci_type"] == "server"
      assert ci["attributes"]["cores"] == 8

      # And the type is part of the registry now, for everyone in the Workspace.
      assert {:ok, types} = CI.types(workspace)
      assert Enum.any?(types, &(&1["id"] == "server"))
    end

    test "a CI missing a required attribute is refused, naming the attribute", %{
      workspace: workspace
    } do
      {:ok, _} = CI.register_type(workspace, @server_type)

      assert {:error, reason} =
               CI.create(workspace, %{
                 "ci_type" => "server",
                 "name" => "web-01",
                 "attributes" => %{"cores" => 8}
               })

      assert reason =~ "region", "the refusal must name the missing attribute"

      assert {:ok, []} = CI.list(workspace)
    end

    test "a CI whose attributes violate the type's schema is refused", %{workspace: workspace} do
      {:ok, _} = CI.register_type(workspace, @server_type)

      # `cores` is declared an integer.
      assert {:error, reason} =
               CI.create(workspace, %{
                 "ci_type" => "server",
                 "name" => "web-01",
                 "attributes" => %{"region" => "eu-west-1", "cores" => "eight"}
               })

      assert reason =~ "cores", "the refusal must name the offending attribute"

      assert {:ok, []} = CI.list(workspace)
    end

    test "a valid CI is accepted, and the defaults are the product's", %{workspace: workspace} do
      {:ok, _} = CI.register_type(workspace, @server_type)

      assert {:ok, ci} =
               CI.create(workspace, %{
                 "ci_type" => "server",
                 "name" => "web-01",
                 "attributes" => %{"region" => "eu-west-1", "cores" => 8}
               })

      assert ci["name"] == "web-01"
      assert ci["lifecycle_state"] == "active"
      assert ci["criticality"] == "medium"
      assert ci["attributes"]["region"] == "eu-west-1"

      # And it is readable afterwards — the same row.
      assert {:ok, read} = CI.get(workspace, ci["id"])
      assert read["id"] == ci["id"]
      assert read["attributes"] == ci["attributes"]
    end

    test "a CI with a lifecycle state or criticality outside the vocabulary is refused", %{
      workspace: workspace
    } do
      {:ok, _} = CI.register_type(workspace, @server_type)

      assert {:error, reason} =
               CI.create(workspace, %{
                 "ci_type" => "server",
                 "name" => "web-01",
                 "lifecycle_state" => "on fire",
                 "attributes" => %{"region" => "eu-west-1"}
               })

      assert reason =~ "on fire"
      assert {:ok, []} = CI.list(workspace)
    end
  end

  describe "relations are typed" do
    setup %{workspace: workspace} do
      {:ok, _} = CI.register_type(workspace, @server_type)
      {:ok, _} = CI.register_relation_kind(workspace, @runs_on_kind)

      {:ok, host} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "host-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      {:ok, guest} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "guest-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      %{host: host, guest: guest}
    end

    test "a relation between two CIs of the right tables is accepted", %{
      workspace: workspace,
      host: host,
      guest: guest
    } do
      assert {:ok, edge} = CI.relate(workspace, host["id"], "runs_on", guest["id"])
      assert edge
    end

    test "a relation between the wrong tables is refused", %{workspace: workspace, host: host} do
      # A kind that says it joins a CI to an Incident, not to a CI.
      {:ok, _} =
        CI.register_relation_kind(workspace, %{
          "id" => "belongs_to_incident",
          "label" => "belongs to incident",
          "from_table" => "ci",
          "to_table" => "incident",
          "inverse" => "has_ci"
        })

      {:ok, other} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "other-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      assert {:error, _reason} =
               CI.relate(workspace, host["id"], "belongs_to_incident", other["id"])

      # And nothing was related: the edge is not in the graph.
      assert {:ok, %{nodes: nodes}} = CI.relations(workspace, host["id"], :out, 5)
      assert nodes == []
    end

    test "an unregistered relation kind is refused", %{
      workspace: workspace,
      host: host,
      guest: guest
    } do
      assert {:error, _reason} = CI.relate(workspace, host["id"], "no_such_kind", guest["id"])

      assert {:ok, %{nodes: nodes}} = CI.relations(workspace, host["id"], :out, 5)
      assert nodes == []
    end

    test "the inverse of a relation is visible", %{
      workspace: workspace,
      host: host,
      guest: guest
    } do
      {:ok, _} = CI.relate(workspace, host["id"], "runs_on", guest["id"])

      assert {:ok, %{nodes: out_nodes}} = CI.relations(workspace, host["id"], :out, 5)
      assert Enum.any?(out_nodes, &(&1["id"] == guest["id"]))

      assert {:ok, %{nodes: in_nodes}} = CI.relations(workspace, guest["id"], :in, 5)
      assert Enum.any?(in_nodes, &(&1["id"] == host["id"]))
    end
  end

  describe "the traversal is bounded" do
    test "a graph deeper than the bound is not traversed past it", %{workspace: workspace} do
      {:ok, _} = CI.register_type(workspace, @server_type)
      {:ok, _} = CI.register_relation_kind(workspace, @runs_on_kind)

      # A chain of seven: c1 -> c2 -> ... -> c7.
      cids =
        for index <- 1..7 do
          {:ok, ci} =
            CI.create(workspace, %{
              "ci_type" => "server",
              "name" => "c#{index}",
              "attributes" => %{"region" => "eu-west-1"}
            })

          ci["id"]
        end

      for [from, to] <- Enum.chunk_every(cids, 2, 1, :discard) do
        {:ok, _} = CI.relate(workspace, from, "runs_on", to)
      end

      last = List.last(cids)

      assert {:ok, %{nodes: shallow}} = CI.relations(workspace, last, :in, 1)
      assert {:ok, %{nodes: bounded}} = CI.relations(workspace, last, :in, 5)

      assert length(shallow) < length(bounded),
             "a deeper bound must reach further: the traversal ignored the depth " <>
               "(depth 1 returned #{length(shallow)} nodes, depth 5 returned " <>
               "#{length(bounded)}). `docs/32` bounds the traversal at depth 5 and " <>
               "`Veritas.Core.CI.relations/4` documents the depth as the bound. " <>
               "Owner: the BEAM Engineer."

      assert length(bounded) < 7,
             "the traversal must stop at the bound: it reached #{length(bounded)} of 6 dependents"
    end

    test "the impact of a CI lists the CIs that depend on it", %{workspace: workspace} do
      {:ok, _} = CI.register_type(workspace, @server_type)
      {:ok, _} = CI.register_relation_kind(workspace, @runs_on_kind)

      {:ok, host} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "host-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      {:ok, dependent} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "dependent-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      {:ok, _} = CI.relate(workspace, dependent["id"], "runs_on", host["id"])

      assert {:ok, impact} = CI.impact(workspace, host["id"], 2)

      ids =
        impact
        |> Map.get(:dependents, [])
        |> Enum.map(fn node -> if is_map(node), do: node["id"], else: node end)

      assert dependent["id"] in ids,
             "the impact must list the CI that depends on it; it listed #{inspect(ids)}"
    end
  end

  describe "CIs are isolated by Workspace" do
    test "a CI in one Workspace is invisible in another", %{workspace: workspace} do
      {:ok, _} = CI.register_type(workspace, @server_type)

      {:ok, ci} =
        CI.create(workspace, %{
          "ci_type" => "server",
          "name" => "web-01",
          "attributes" => %{"region" => "eu-west-1"}
        })

      other = "other_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      :ok = Veritas.Core.Test.StoreCase.migrate(other)

      # The second Workspace is removed with the first: a test run must leave
      # the store as it found it.
      on_exit(fn -> Veritas.Core.Test.StoreCase.remove_workspace(other) end)

      assert {:ok, nil} = CI.get(other, ci["id"])
      assert {:ok, []} = CI.list(other)

      case CI.impact(other, ci["id"], 2) do
        {:error, _reason} -> :ok
        {:ok, impact} -> assert Map.get(impact, :dependents, []) == []
      end
    end
  end
end
