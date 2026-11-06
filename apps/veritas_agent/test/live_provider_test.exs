defmodule Veritas.Agent.LiveProviderTest do
  @moduledoc """
  The domain runner against the **real** configured provider.

  This is live-provider evidence, kept distinct from the source tests: it
  reaches the network with a real credential, so it is excluded by default
  and runs only as `mix test --only live_provider`, under the secret loader
  that puts the credential in the environment.

  What it proves is the demo's claim: the catalogue is the provider's own,
  and a model the operator picks from it — not the configured default — is
  the model that answers. The credential is read by the adapter at call
  time and never appears in an assertion or an output.

  The second case is the workflow AI step end to end on that provider. The
  store is this app's test store, `Veritas.Store.Memory`, not SurrealDB; the
  core suite proves the same persistence rules on SurrealDB with a scripted
  model.
  """
  use ExUnit.Case, async: false

  alias Veritas.Agentic.Runner
  alias Veritas.Core.{Audit, Principal, Workflows}

  @moduletag :live_provider

  @credential_env "OLLAMA_API_KEY"
  @workspace "agent_live_test"

  # The workflow AI step's own instruction (`Veritas.Core.Workflows.ask_ai/5`),
  # repeated here so the live call is shaped like the demo's call and not like
  # the console's tool-using one. A model told to answer "by calling the tools
  # you are given" and given none will invent a tool call; the workflow step
  # does not tell it that.
  @workflow_system_prompt "You are the Veritas workflow assistant. Follow the requested output format. Use only recorded facts as evidence; label hypotheses. Produce a proposal for a human to review. Never claim to have executed an action."

  # Preferred picks, in order: chat models seen to answer. The catalogue's
  # order changes between calls, so the pick must not depend on it.
  @preferred ~w(gpt-oss:20b glm-5.3-flash kimi-k3 gemma4:31b)

  setup do
    if System.get_env(@credential_env) in [nil, ""] do
      raise "#{@credential_env} is not in the environment; run this suite under the secret loader"
    end

    previous = Application.get_env(:veritas_core, :providers)

    Application.put_env(:veritas_core, :providers,
      ollama_cloud: [
        kind: :hosted,
        adapter: :openai_compatible,
        base_url: System.get_env("VERITAS_LIVE_BASE_URL", "https://ollama.com/v1"),
        model: System.get_env("VERITAS_LIVE_DEFAULT_MODEL", "mistral-large-4"),
        credential_env: @credential_env,
        capabilities: [:tools, :json_object]
      ]
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:veritas_core, :providers)
        value -> Application.put_env(:veritas_core, :providers, value)
      end
    end)

    :ok
  end

  test "a non-default model from the live catalogue answers through the runner" do
    actor = %Principal{id: "live-test", workspace: @workspace, roles: []}

    assert {:ok, models} = Runner.models(@workspace)
    ids = Enum.map(models, & &1.id)
    IO.puts("[live_provider] catalogue: #{length(ids)} models")
    IO.puts("[live_provider] #{Enum.join(ids, ", ")}")
    assert length(ids) > 1

    default = Application.get_env(:veritas_core, :providers)[:ollama_cloud][:model]
    assert default in ids, "the configured default #{default} is not in the live catalogue"

    pick = pick_model(ids, default)
    assert pick, "the catalogue has no second chat model to pick"
    assert pick != default

    started = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Runner.ask(
               @workspace,
               "Summarize this ticket in two sentences and propose one next action.\n\nRecorded context:\n" <>
                 Jason.encode!(%{
                   "ticket" => %{"title" => "Checkout latency", "state" => "open"},
                   "answers" => %{
                     "intake" => %{"service" => "checkout", "impact" => "p95 +400ms"}
                   }
                 }),
               actor: actor,
               model: pick,
               tool_names: [],
               system_prompt: @workflow_system_prompt,
               timeout: 90_000
             )

    elapsed = System.monotonic_time(:millisecond) - started

    IO.puts(
      "[live_provider] asked #{result.provider}/#{result.model} (default #{default}) in #{elapsed}ms"
    )

    IO.puts("[live_provider] answer: #{String.slice(result.answer || "", 0, 240)}")

    assert result.model == pick
    assert result.tools_used == []
    assert is_binary(result.answer) and String.trim(result.answer) != ""
  end

  test "a workflow AI step drafts through the live provider and waits for a person" do
    workspace = "agent_live_wf_#{System.unique_integer([:positive])}"
    admin = Principal.new("owner", workspace, [:platform_admin])
    operator = Principal.new("operator", workspace, [:incident_manager, :service_desk_agent])
    assert {:ok, :seeded} = seed_lifecycle(workspace)

    assert {:ok, models} = Runner.models(workspace)
    default = Application.get_env(:veritas_core, :providers)[:ollama_cloud][:model]
    pick = pick_model(Enum.map(models, & &1.id), default)
    assert pick, "the catalogue has no second chat model to pick"

    {:ok, workflow} = Workflows.save(workspace, nil, Workflows.template(), admin)
    {:ok, _} = Workflows.publish(workspace, workflow["id"], workflow["revision"], admin)

    {:ok, run} =
      Workflows.start(
        workspace,
        workflow["id"],
        %{"title" => "Checkout latency", "answers" => %{"service" => "checkout"}},
        operator
      )

    assert %{"kind" => "ai", "id" => step} = Workflows.current_step(run)

    started = System.monotonic_time(:millisecond)

    assert {:ok, drafted} =
             Workflows.draft(workspace, run["ticket"], operator, model: pick, timeout: 90_000)

    elapsed = System.monotonic_time(:millisecond) - started
    proposal = Workflows.current_output(drafted)

    IO.puts(
      "[live_provider] workflow step #{step} drafted by #{proposal["provider"]}/#{proposal["model"]} " <>
        "(default #{default}) in #{elapsed}ms on #{inspect(Veritas.Store.Config.adapter())}"
    )

    IO.puts("[live_provider] proposal: #{String.slice(proposal["text"], 0, 240)}")

    assert proposal["model"] == pick
    assert to_string(proposal["provider"]) == "ollama_cloud"
    assert String.trim(proposal["text"]) != ""

    # The proposal is not accepted: without a person's explicit approval the
    # step does not complete and the run stays where it was.
    assert {:error, :approval_required} =
             Workflows.complete(workspace, run["ticket"], %{}, operator,
               expected_revision: drafted["revision"]
             )

    assert {:ok, %{"data" => %{"current_step" => ^step}}} =
             Workflows.run(workspace, run["ticket"], operator)

    assert {:ok, _} =
             Workflows.complete(workspace, run["ticket"], %{}, operator,
               expected_revision: drafted["revision"],
               approve: true
             )

    assert {:ok, accepted} = Workflows.run(workspace, run["ticket"], operator)
    assert step in accepted["data"]["completed_steps"]
    refute accepted["data"]["current_step"] == step
    assert accepted["data"]["outputs"][step]["text"] == proposal["text"]
    assert {:ok, :intact} = Audit.verify(workspace)
  end

  # `Veritas.Store.Memory` has no migration, so the ticket lifecycle the
  # SurrealDB migration writes is written here from the same source
  # (`Schema.transitions/0`), with the same fields.
  defp seed_lifecycle(workspace) do
    Veritas.Store.transaction(workspace, fn tx ->
      Enum.each(Veritas.Store.Surreal.Schema.transitions(), fn {type, from, to} ->
        {:ok, _} =
          Veritas.Store.put(tx, :ticket_transition, %{
            "id" => "#{type}__#{from}__#{to}",
            "ticket_type" => type,
            "from_state" => from,
            "to_state" => to,
            "requires_approval" => false,
            "sla_effect" => "none"
          })
      end)

      {:ok, :seeded}
    end)
  end

  defp pick_model(ids, default) do
    present(System.get_env("VERITAS_LIVE_PICK")) ||
      Enum.find(@preferred, &(&1 in ids and &1 != default)) ||
      Enum.find(ids, &(&1 != default and not String.contains?(&1, "embed")))
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value
end
