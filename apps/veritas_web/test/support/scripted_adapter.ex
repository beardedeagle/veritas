defmodule Veritas.Web.ScriptedAdapter do
  @moduledoc """
  A scripted adapter, for the console's end-to-end proof.

  The corpus says the Port's conformance suite runs against a scripted
  adapter (`docs/39` §9). This one is **scripted**: it asks for one tool and
  then answers, so a run can be proved end to end without a model, a
  runtime or a key.

  It is a test double and it says so: it never leaves the test tree.
  Designer scenarios emit an invalid workflow, then a corrected one when validation feedback arrives.
  """

  @behaviour Veritas.Agentic.LLM
  @behaviour Veritas.Agentic.LLM.Adapter

  alias Veritas.Agentic.LLM

  @doc "The adapter's identifier."
  @impl Veritas.Agentic.LLM.Adapter
  def id, do: :scripted

  @doc "The scripted adapter accepts any configuration."
  @impl Veritas.Agentic.LLM.Adapter
  def init(config) when is_map(config), do: {:ok, config}

  @doc """
  Returns the configured workflow scenario, or asks for a tool and then answers.
  """
  @impl Veritas.Agentic.LLM
  def complete(%LLM.Request{} = request, %{base_url: scenario}, _opts)
      when scenario in [
             "http://workflow-design-repair.invalid",
             "http://workflow-design-invalid.invalid"
           ] do
    context =
      request.messages
      |> List.last()
      |> Map.fetch!(:content)
      |> String.split("\n\nRecorded context:\n", parts: 2)
      |> List.last()
      |> Jason.decode!()

    definition =
      Veritas.Core.Workflows.template(context["ticket_type"] || "incident")
      |> Map.put("name", "AI checkout incident response")

    definition =
      if scenario == "http://workflow-design-invalid.invalid" or
           is_nil(context["validation_error"]),
         do:
           put_in(definition, ["steps", Access.at(0), "fields", Access.at(0), "type"], "dropdown"),
         else: definition

    {:ok,
     %LLM.Response{
       id: "scripted-design",
       model: request.model.id,
       content: Jason.encode!(definition),
       finish_reason: :stop
     }}
  end

  def complete(%LLM.Request{messages: messages} = request, config, _opts) do
    # The script is stateless: a request that already carries a tool's answer
    # gets the answer, and any other request asks for the tool.
    if Enum.any?(messages, &(&1.role == :tool)) do
      {:ok,
       %LLM.Response{
         id: "scripted-2",
         model: request.model.id,
         content: "The answer, from the tool the agent called.",
         finish_reason: :stop
       }}
    else
      {:ok,
       %LLM.Response{
         id: "scripted-1",
         model: request.model.id,
         content: "",
         tool_calls: [
           %LLM.ToolCall{
             id: "call-1",
             name: config[:tool] || "search_ci",
             arguments: config[:arguments] || %{"limit" => 5}
           }
         ],
         finish_reason: :tool_calls
       }}
    end
  end

  @doc "The scripted adapter does not stream."
  @impl Veritas.Agentic.LLM
  def stream(_request, _config, _opts) do
    {:error, %LLM.Error{code: :unsupported, message: "the scripted adapter does not stream"}}
  end

  @doc """
  Two scripted models, so a screen can prove the operator's choice reaches the run.

  A provider whose base URL is `http://unexpected.invalid` fails in a shape no
  screen knows how to describe, carrying a provider body that must never reach
  the operator.
  """
  @impl Veritas.Agentic.LLM
  def models(%{base_url: "http://unexpected.invalid"}) do
    {:error, {:unexpected, "RAW-PROVIDER-BODY"}}
  end

  def models(_config) do
    {:ok,
     [
       %LLM.Model{id: "scripted-1", provider: "scripted", supports: [:tools]},
       %LLM.Model{id: "scripted-2", provider: "scripted", supports: [:tools]}
     ]}
  end
end
