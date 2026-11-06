defmodule Veritas.Core.Workflows do
  @moduledoc """
  Editable operational steps around a ticket's canonical lifecycle.

  Drafts are editable, published definitions are copied into each run, and
  progress, ticket transitions and audit events commit together. AI produces
  proposals; only an authorized human can complete a step or publish a flow.
  """
  alias Veritas.Core.{Audit, Policy, Principal, Tickets, WorkspaceLock}
  alias Veritas.Store

  @kinds ~w(intake manual ai approval)
  @phases ~w(intake processing after_action)
  @field_types ~w(text textarea number select checkbox)

  @doc "Returns an editable workflow definition for the ticket type without saving it."
  @spec template(Tickets.ticket_type()) :: map()
  def template(type \\ "incident") do
    states =
      if type == "incident",
        do: ~w(acknowledged in_progress resolved closed),
        else: ["", "", "", ""]

    %{
      "name" => "#{type |> String.replace("_", " ") |> String.capitalize()} response",
      "ticket_type" => type,
      "description" => "From intake to reviewed follow-up. Edit every step to fit your team.",
      "steps" => [
        %{
          "id" => "intake",
          "name" => "Report the issue",
          "kind" => "intake",
          "phase" => "intake",
          "instructions" => "Describe what happened and who is affected.",
          "fields" => [
            %{
              "key" => "service",
              "label" => "Affected service",
              "type" => "text",
              "required" => true
            }
          ],
          "next" => ["triage"]
        },
        %{
          "id" => "triage",
          "name" => "AI triage",
          "kind" => "ai",
          "phase" => "processing",
          "instructions" =>
            "Assess impact, summarize the issue and propose a concrete investigation plan. Distinguish facts from hypotheses.",
          "fields" => [],
          "state" => Enum.at(states, 0),
          "next" => ["processing"]
        },
        %{
          "id" => "processing",
          "name" => "Investigate and restore",
          "kind" => "manual",
          "phase" => "processing",
          "instructions" => "Record the investigation and the action taken.",
          "fields" => [
            %{
              "key" => "work",
              "label" => "Work performed",
              "type" => "textarea",
              "required" => true
            }
          ],
          "state" => Enum.at(states, 1),
          "next" => ["resolution"]
        },
        %{
          "id" => "resolution",
          "name" => "Verify resolution",
          "kind" => "approval",
          "phase" => "processing",
          "instructions" => "Confirm service is restored and record the evidence.",
          "fields" => [
            %{
              "key" => "evidence",
              "label" => "Verification evidence",
              "type" => "textarea",
              "required" => true
            }
          ],
          "state" => Enum.at(states, 2),
          "next" => ["follow_up"]
        },
        %{
          "id" => "follow_up",
          "name" => "AI after-action review",
          "kind" => "ai",
          "phase" => "after_action",
          "instructions" =>
            "Draft an after-action review from the recorded facts: impact, timeline, work performed, verification, lessons learned and follow-up actions. Do not invent evidence.",
          "fields" => [],
          "state" => Enum.at(states, 3),
          "next" => []
        }
      ]
    }
  end

  @doc "Validates definition structure, fields and routing; publication checks ticket lifecycle paths."
  @spec validate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate(definition) when is_map(definition) do
    steps = definition["steps"]

    cond do
      not text?(definition["name"]) ->
        {:error, "Give the workflow a name."}

      not optional_text?(definition["description"]) ->
        {:error, "The workflow description must be text."}

      definition["ticket_type"] not in Tickets.ticket_types() ->
        {:error, "Choose a known ticket type."}

      not is_list(steps) or steps == [] or length(steps) > 100 ->
        {:error, "A workflow needs between 1 and 100 steps."}

      hd(steps)["kind"] != "intake" ->
        {:error, "The first step must be intake."}

      Enum.count(steps, &(&1["kind"] == "intake")) != 1 ->
        {:error, "A workflow has one intake step."}

      length(Enum.uniq_by(steps, & &1["id"])) != length(steps) ->
        {:error, "Step identifiers must be unique."}

      true ->
        validate_steps(definition, steps)
    end
  rescue
    _ -> {:error, "The workflow definition is malformed."}
  end

  def validate(_), do: {:error, "The workflow definition must be an object."}

  defp validate_steps(definition, steps) do
    ids = MapSet.new(steps, & &1["id"])

    error =
      Enum.find_value(steps, fn step ->
        validate_step_content(step) || validate_step_routes(step, ids, hd(steps)["id"]) ||
          validate_fields(step["fields"] || [])
      end)

    reachable = reachable(steps, hd(steps)["id"], MapSet.new())

    cond do
      error ->
        {:error, error}

      MapSet.size(reachable) != length(steps) ->
        {:error, "Every step must be reachable from intake."}

      not Enum.any?(steps, &(&1["next"] == [])) ->
        {:error, "A workflow needs a finishing step."}

      Enum.any?(steps, fn step ->
        from = reachable(steps, step["id"], MapSet.new())
        not Enum.any?(steps, &(&1["next"] == [] and MapSet.member?(from, &1["id"])))
      end) ->
        {:error, "Every branch must have a path to a finishing step."}

      true ->
        {:ok, Map.take(definition, ~w(name ticket_type description steps))}
    end
  end

  defp validate_step_content(step) do
    cond do
      not identifier?(step["id"]) -> "Step identifiers use letters, numbers and underscores."
      not text?(step["name"]) -> "Every step needs a name."
      not optional_text?(step["instructions"]) -> "Step instructions must be text."
      not optional_text?(step["state"]) -> "A ticket state must be text."
      not optional_text?(step["model"]) -> "An AI model must be text."
      step["kind"] not in @kinds -> "Unknown step kind."
      step["phase"] not in @phases -> "Choose intake, processing or after_action."
      not is_list(step["fields"] || []) -> "Step fields must be a list."
      true -> nil
    end
  end

  defp validate_step_routes(step, ids, intake_id) do
    cond do
      not is_list(step["next"]) or not Enum.all?(step["next"], &MapSet.member?(ids, &1)) ->
        "A branch points at a missing step."

      step["id"] in step["next"] ->
        "A step cannot route directly to itself."

      intake_id in step["next"] ->
        "A processing branch cannot return to intake."

      step["kind"] == "intake" and length(step["next"]) > 1 ->
        "Intake must have one next step."

      true ->
        nil
    end
  end

  defp validate_fields(fields) do
    cond do
      length(fields) > 50 ->
        "A step can have at most 50 fields."

      length(Enum.uniq_by(fields, & &1["key"])) != length(fields) ->
        "Field identifiers must be unique within a step."

      true ->
        Enum.find_value(fields, fn f ->
          cond do
            not identifier?(f["key"]) or not text?(f["label"]) ->
              "Every field needs an identifier and a label."

            f["type"] not in @field_types ->
              "Unknown field type #{inspect(f["type"], printable_limit: 80)} for field " <>
                "#{inspect(f["key"])}. Use #{Enum.join(@field_types, ", ")}."

            f["required"] not in [nil, true, false] ->
              "A field's required setting must be true or false."

            f["type"] == "select" and
                (not is_list(f["options"]) or f["options"] == [] or
                   not Enum.all?(f["options"], &text?/1)) ->
              "Select fields need nonempty choices."

            true ->
              nil
          end
        end)
    end
  end

  defp reachable(steps, id, seen) do
    if MapSet.member?(seen, id) do
      seen
    else
      step = Enum.find(steps, &(&1["id"] == id))
      Enum.reduce((step && step["next"]) || [], MapSet.put(seen, id), &reachable(steps, &1, &2))
    end
  end

  @doc "Lists up to 200 workflows, newest first, for a principal with Workspace read authority."
  @spec list(Store.workspace(), Principal.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list(workspace, principal) do
    with :ok <- permit(principal, "ticket:read", workspace) do
      Store.transaction(workspace, fn tx ->
        Store.list(tx, :workflow, %{where: [], order_by: [updated_at: :desc], limit: 200})
      end)
    end
  end

  @doc "Reads a workflow and its saved and published definitions under Workspace authorization."
  @spec get(Store.workspace(), Store.record_id(), Principal.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def get(workspace, id, principal) do
    with :ok <- permit(principal, "ticket:read", workspace) do
      Store.transaction(workspace, fn tx -> fetch(tx, :workflow, id) end)
    end
  end

  @doc """
  Saves a draft for an authorized human administrator; nil id creates a workflow.

  Updating a draft requires `:expected_revision`. Saving does not publish the draft.
  """
  @spec save(Store.workspace(), Store.record_id() | nil, term(), Principal.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def save(workspace, id, definition, principal, opts \\ []) do
    with :ok <- permit(principal, "account:administrate", workspace),
         :ok <- require_human(principal),
         {:ok, definition} <- validate(definition) do
      write(workspace, fn tx ->
        with {:ok, old} <- existing(tx, :workflow, id),
             :ok <- revision(old, opts[:expected_revision]) do
          row =
            Map.merge(old || %{}, %{
              "id" => id || identifier("wf"),
              "name" => definition["name"],
              "ticket_type" => definition["ticket_type"],
              "definition" => definition,
              "revision" => ((old || %{})["revision"] || 0) + 1,
              "updated_at" => DateTime.utc_now()
            })

          persist(tx, workspace, :workflow, row, principal, "Workflow draft saved", %{
            "revision" => row["revision"],
            "definition" => definition
          })
        end
      end)
    end
  end

  @doc "Publishes the expected draft revision after human authorization and lifecycle validation."
  @spec publish(Store.workspace(), Store.record_id(), integer(), Principal.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def publish(workspace, id, expected_revision, principal) do
    with :ok <- permit(principal, "account:administrate", workspace),
         :ok <- require_human(principal) do
      write(workspace, fn tx ->
        with {:ok, w} <- fetch(tx, :workflow, id),
             :ok <- revision(w, expected_revision),
             {:ok, definition} <- validate(w["definition"]),
             :ok <- lifecycle(tx, definition) do
          row =
            Map.merge(w, %{
              "published_definition" => definition,
              "published_revision" => w["revision"],
              "updated_at" => DateTime.utc_now()
            })

          persist(tx, workspace, :workflow, row, principal, "Workflow published", %{
            "published_revision" => row["published_revision"]
          })
        end
      end)
    end
  end

  defp lifecycle(tx, definition) do
    with {:ok, transitions} <- workflow_transitions(tx, definition["ticket_type"]) do
      check_lifecycle(definition, transitions)
    end
  end

  defp workflow_transitions(tx, type),
    do: Store.list(tx, :ticket_transition, %{where: [ticket_type: type], limit: 1000})

  defp check_lifecycle(definition, transitions) do
    check_path(
      definition["steps"],
      transitions,
      [{hd(definition["steps"])["id"], Tickets.initial_state(definition["ticket_type"])}],
      MapSet.new()
    )
  end

  defp check_path(_steps, _transitions, [], _seen), do: :ok

  defp check_path(steps, transitions, [{id, from} = pair | rest], seen) do
    if MapSet.member?(seen, pair) do
      check_path(steps, transitions, rest, seen)
    else
      step = Enum.find(steps, &(&1["id"] == id))
      to = if step["state"] in [nil, ""], do: from, else: step["state"]

      if to == from or
           Enum.any?(transitions, &(&1["from_state"] == from and &1["to_state"] == to)) do
        next = Enum.map(step["next"], &{&1, to})
        check_path(steps, transitions, rest ++ next, MapSet.put(seen, pair))
      else
        {:error,
         "#{step["name"]}: #{from} → #{to} is not a legal ticket transition. Edit the step's target state."}
      end
    end
  end

  @doc """
  Starts a ticket and run from the published definition for an authorized human.

  Intake attributes include a title and field answers. A denied intake rolls back
  creation before recording its refusal in a separate transaction.
  """
  @spec start(Store.workspace(), Store.record_id(), map(), Principal.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def start(workspace, id, attrs, principal) do
    with {:ok, workflow} <- get(workspace, id, principal),
         definition when is_map(definition) <-
           workflow["published_definition"] || {:error, :workflow_not_published},
         :ok <- permit(principal, "ticket:write", workspace, definition["ticket_type"]),
         :ok <- require_human(principal),
         true <- text?(attrs["title"]) || {:error, "Give the ticket a title."},
         {:ok, answers} <- answers(hd(definition["steps"]), attrs["answers"] || %{}) do
      write(workspace, fn tx ->
        # Read publication under the same lock that commits the new ticket.
        with {:ok, current} <- fetch(tx, :workflow, id),
             true <-
               current["published_revision"] == workflow["published_revision"] ||
                 {:error, :revision_conflict},
             {:ok, ticket} <- open_ticket(tx, workspace, definition, attrs, principal) do
          intake = hd(definition["steps"])
          next = List.first(intake["next"])

          data = %{
            "current_step" => next || "",
            "answers" => %{intake["id"] => answers},
            "outputs" => %{},
            "approved_outputs" => [],
            "completed_steps" => [intake["id"]]
          }

          row = %{
            "id" => ticket["id"],
            "ticket" => ticket["id"],
            "workflow" => id,
            "workflow_revision" => current["published_revision"],
            "definition" => definition,
            "data" => data,
            "status" => if(next, do: "active", else: "completed"),
            "revision" => 1,
            "updated_at" => DateTime.utc_now()
          }

          persist(tx, workspace, :workflow_run, row, principal, "Ticket workflow started", %{
            "workflow" => id,
            "workflow_revision" => current["published_revision"],
            "intake" => answers
          })
        end
      end)
      |> record_intake_refusal(workspace, id, definition, principal)
    else
      {:error, _} = error -> error
      _ -> {:error, :workflow_not_published}
    end
  end

  defp open_ticket(tx, workspace, definition, attrs, principal) do
    with {:ok, ticket} <-
           Tickets.open_in_transaction(
             tx,
             workspace,
             definition["ticket_type"],
             Map.put(attrs, "requester", principal.id),
             Principal.audit_actor(principal)
           ),
         {:ok, moved} <-
           move_ticket(
             tx,
             workspace,
             %{"ticket" => ticket["id"]},
             hd(definition["steps"]),
             principal
           ) do
      # A denied intake must roll back creation, rather than commit an orphan ticket.
      case moved do
        {:denied, reason} -> {:error, {:intake_denied, reason}}
        ticket -> {:ok, ticket}
      end
    end
  end

  defp record_intake_refusal(
         {:error, {:intake_denied, reason}},
         workspace,
         id,
         definition,
         principal
       ) do
    # Creation and its audit have rolled back; record the original refusal in a fresh transaction.
    with {:ok, _} <-
           write(workspace, fn tx ->
             Audit.append(tx, workspace, %{
               subject: id,
               subject_table: "workflow",
               actor: Principal.audit_actor(principal),
               from_state: nil,
               to_state: "refused",
               reason: reason,
               correlation_id: nil,
               diff: %{
                 "capability" => "ticket:transition",
                 "ticket_type" => definition["ticket_type"],
                 "intake_state" => hd(definition["steps"])["state"]
               }
             })
           end) do
      {:error, reason}
    end
  end

  defp record_intake_refusal(result, _workspace, _id, _definition, _principal), do: result

  @doc "Reads a ticket's authorized workflow run, recovering missing legacy history from approval audit."
  @spec run(Store.workspace(), Store.record_id(), Principal.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def run(workspace, ticket_id, principal) do
    with :ok <- permit(principal, "ticket:read", workspace) do
      Store.transaction(workspace, fn tx -> fetch(tx, :workflow_run, ticket_id) end)
    end
  end

  @doc "Returns the active step from the run's immutable definition, or nil when finished."
  @spec current_step(map()) :: map() | nil
  def current_step(run),
    do: Enum.find(run["definition"]["steps"], &(&1["id"] == run["data"]["current_step"]))

  @doc "The usable proposal for the current visit; a rework loop must request a new one."
  @spec current_output(map()) :: map() | nil
  def current_output(run) do
    step = current_step(run)
    output = step && get_in(run, ["data", "outputs", step["id"]])
    completed = run["data"]["completed_steps"]

    if is_map(output) and text?(output["text"]) and
         (output["step_visit"] == length(completed) or
            (is_nil(output["step_visit"]) and step["id"] not in completed)), do: output, else: nil
  end

  @doc "Approved AI output for a zero-based completed-step index; pending proposals are excluded."
  @spec approved_output(map(), non_neg_integer()) :: map() | nil
  def approved_output(run, step_visit) do
    Enum.find(run["data"]["approved_outputs"] || [], &(&1["step_visit"] == step_visit))
  end

  defp accept_output(row, %{"kind" => "ai"} = step, principal) do
    output =
      approved_entry(
        current_output(row),
        step["id"],
        length(row["data"]["completed_steps"]),
        principal.id,
        DateTime.to_iso8601(DateTime.utc_now())
      )

    Map.update!(row["data"], "approved_outputs", &(&1 ++ [output]))
  end

  defp accept_output(row, _step, _principal), do: row["data"]

  defp approved_entry(output, step, visit, actor, timestamp) do
    timestamp =
      case timestamp do
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
        value -> value
      end

    Map.merge(output, %{
      "step" => step,
      "step_visit" => visit,
      "approved_by" => actor,
      "approved_at" => timestamp
    })
  end

  @doc """
  Completes the current step with field answers and the expected run revision.

  Requires `:expected_revision`; `:next` selects a configured branch. AI and approval
  steps also require explicit human `approve: true`; AI steps need a current proposal.
  """
  @spec complete(Store.workspace(), Store.record_id(), map(), Principal.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(workspace, ticket_id, values, principal, opts \\ []) do
    with {:ok, loaded} <- run(workspace, ticket_id, principal),
         :ok <- permit(principal, "ticket:write", workspace, loaded["definition"]["ticket_type"]),
         :ok <- require_human(principal) do
      write(workspace, fn tx ->
        with {:ok, row} <- fetch(tx, :workflow_run, ticket_id),
             :ok <- revision(row, opts[:expected_revision]),
             %{} = step <- current_step(row) || {:error, :workflow_completed},
             {:ok, values} <- answers(step, values),
             :ok <- require_draft(row, step),
             :ok <- require_approval(step, principal, opts),
             {:ok, next} <- destination(step, opts[:next]),
             {:ok, moved} <- move_ticket(tx, workspace, row, step, principal) do
          case moved do
            {:denied, _} = denied ->
              {:ok, denied}

            _ ->
              data =
                accept_output(row, step, principal)
                |> Map.put("current_step", next || "")
                |> Map.update!("answers", &Map.put(&1, step["id"], values))
                |> Map.update!("completed_steps", &(&1 ++ [step["id"]]))

              updated =
                Map.merge(row, %{
                  "data" => data,
                  "status" => if(next, do: "active", else: "completed"),
                  "revision" => row["revision"] + 1,
                  "updated_at" => DateTime.utc_now()
                })

              persist(
                tx,
                workspace,
                :workflow_run,
                updated,
                principal,
                if(step["kind"] in ~w(ai approval),
                  do: "Human approved workflow step",
                  else: "Workflow step completed"
                ),
                %{
                  "step" => step["id"],
                  "answers" => values,
                  "next" => next || "",
                  "accepted_ai_output" => get_in(data, ["outputs", step["id"]]) || %{}
                }
              )
          end
        else
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc """
  Requests and saves an AI proposal for the current visit without approving it.

  A nonblank `:model` overrides the step's model. A changed run revision refuses
  the response, so a late proposal cannot overwrite concurrently accepted work.
  """
  @spec draft(Store.workspace(), Store.record_id(), Principal.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def draft(workspace, ticket_id, principal, opts \\ []) do
    with {:ok, run} <- run(workspace, ticket_id, principal),
         :ok <- permit(principal, "ticket:write", workspace, run["definition"]["ticket_type"]),
         %{"kind" => "ai"} = step <- current_step(run) || {:error, :workflow_completed},
         {:ok, ticket} <- Tickets.read(workspace, ticket_id),
         {:ok, result} <-
           ask_ai(
             workspace,
             step["instructions"] || "Summarize this ticket and propose next actions.",
             %{
               "ticket" => ticket,
               "answers" => run["data"]["answers"],
               "previous_outputs" => run["data"]["outputs"]
             },
             principal,
             Keyword.put(
               opts,
               :model,
               if(text?(opts[:model]), do: opts[:model], else: step["model"])
             )
           ),
         true <-
           text?(result.answer) ||
             {:error, "The model returned no usable proposal. Try again or select another model."} do
      write(workspace, fn tx ->
        with {:ok, current} <- fetch(tx, :workflow_run, ticket_id),
             :ok <- revision(current, run["revision"]) do
          output = %{
            "text" => result.answer,
            "provider" => result.provider,
            "model" => result.model,
            "step_visit" => length(current["data"]["completed_steps"])
          }

          data = put_in(current["data"], ["outputs", step["id"]], output)

          updated =
            Map.merge(current, %{
              "data" => data,
              "revision" => current["revision"] + 1,
              "updated_at" => DateTime.utc_now()
            })

          persist(
            tx,
            workspace,
            :workflow_run,
            updated,
            principal,
            "AI proposed workflow output; human acceptance pending",
            %{"step" => step["id"], "proposal" => output}
          )
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_an_ai_step}
    end
  end

  @doc """
  Generates a structurally and lifecycle-validated proposal for an authorized administrator.

  Accepts an optional `:model` and total `:timeout` in milliseconds (default 30_000).
  An invalid response gets one correction attempt within that budget. Provider errors
  are returned directly. The result is neither saved nor published.
  """
  @spec generate(
          Store.workspace(),
          String.t(),
          Tickets.ticket_type(),
          Principal.t() | nil,
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def generate(workspace, prompt, type, principal, opts \\ []) do
    with :ok <- permit(principal, "account:administrate", workspace),
         true <- text?(prompt) || {:error, "Describe the workflow you want."},
         true <- type in Tickets.ticket_types() || {:error, "Choose a known ticket type."},
         {:ok, transitions} <-
           Store.transaction(workspace, fn tx -> workflow_transitions(tx, type) end) do
      context = %{
        "ticket_type" => type,
        "field_types" => @field_types,
        "step_kinds" => @kinds,
        "phases" => @phases,
        "initial_state" => Tickets.initial_state(type),
        "transitions" => Enum.map(transitions, &Map.take(&1, ~w(from_state to_state)))
      }

      instructions = """
      Design an editable ticket workflow for this request: #{prompt}
      Return only a complete JSON object matching this example: #{Jason.encode!(template(type))}
      Use only the exact field_types, step_kinds and phases in the recorded context.
      Every field needs a unique key, label and type; required is a boolean.
      A select field also needs a nonempty options list of strings.
      Do not use JSON Schema types such as string, integer or boolean as field types.
      Use stable unique step identifiers and next as a list of those identifiers.
      Keep exactly one intake first and a reachable finishing step. Never route back to intake.
      Include meaningful instructions for each AI step. Leave state blank to keep it unchanged,
      or follow the recorded transitions from initial_state on every branch. Do not invent states.
      """

      generate_proposal(workspace, instructions, context, principal, opts)
    else
      {:error, _} = error -> error
    end
  end

  defp generate_proposal(workspace, instructions, context, principal, opts) do
    timeout = opts[:timeout] || 30_000
    deadline = System.monotonic_time(:millisecond) + timeout
    opts = Keyword.put(opts, :timeout, timeout)

    with {:ok, result} <- ask_ai(workspace, instructions, context, principal, opts) do
      case validate_generated(result.answer, context) do
        {:ok, _} = valid ->
          valid

        {:error, reason} ->
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining > 0 do
            correction =
              Map.merge(context, %{
                "validation_error" => reason,
                "previous_workflow" => result.answer
              })

            with {:ok, corrected} <-
                   ask_ai(
                     workspace,
                     instructions <>
                       "\nCorrect the previous workflow using the validation error. Return the complete corrected JSON object.",
                     correction,
                     principal,
                     Keyword.put(opts, :timeout, remaining)
                   ) do
              validate_generated(corrected.answer, context)
            end
          else
            {:error,
             "Workflow generation timed out before a valid draft was returned. " <>
               "Last validation error: #{reason}"}
          end
      end
    end
  end

  defp validate_generated(answer, context) do
    with {:ok, definition} <- decode_definition(answer),
         {:ok, definition} <- validate(Map.put(definition, "ticket_type", context["ticket_type"])),
         :ok <- check_lifecycle(definition, context["transitions"]) do
      {:ok, definition}
    end
  end

  defp ask_ai(workspace, instructions, context, principal, opts) do
    Veritas.Agentic.Runner.ask(
      workspace,
      instructions <> "\n\nRecorded context:\n" <> Jason.encode!(context),
      Keyword.merge(opts,
        actor: principal,
        run_id: identifier("run"),
        system_prompt:
          "You are the Veritas workflow assistant. Follow the requested output format. Use only recorded facts as evidence; label hypotheses. Produce a proposal for a human to review. Never claim to have executed an action.",
        tool_names: []
      )
    )
  end

  defp decode_definition(text) when is_binary(text) do
    text =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")

    case Jason.decode(text) do
      {:ok, %{} = value} ->
        {:ok, value}

      _ ->
        {:error, "The model did not return a valid workflow object. Try again or edit the draft."}
    end
  end

  defp decode_definition(_), do: {:error, "The model returned no workflow."}

  defp move_ticket(tx, workspace, run, step, principal) do
    state = step["state"]

    with {:ok, ticket} <- fetch(tx, :ticket, run["ticket"]) do
      if state in [nil, "", ticket["state"]],
        do: {:ok, ticket},
        else:
          Tickets.transition_in_transaction(tx, workspace, run["ticket"], state, principal,
            reason: "Workflow step: #{step["name"]}"
          )
    end
  end

  defp require_draft(run, %{"kind" => "ai"}) do
    if current_output(run), do: :ok, else: {:error, :ai_draft_required}
  end

  defp require_draft(_, _), do: :ok

  defp require_approval(%{"kind" => kind}, principal, opts) when kind in ["ai", "approval"] do
    if match?(%Principal{kind: :human}, principal) and opts[:approve] == true,
      do: :ok,
      else: {:error, :approval_required}
  end

  defp require_approval(_, _, _), do: :ok

  defp require_human(%Principal{kind: :human}), do: :ok
  defp require_human(_), do: {:error, "An authorized human must perform this workflow action."}

  defp destination(%{"next" => []}, _), do: {:ok, nil}
  defp destination(%{"next" => [one]}, nil), do: {:ok, one}

  defp destination(%{"next" => choices}, chosen) do
    if chosen in choices,
      do: {:ok, chosen},
      else: {:error, "Choose one of the configured next steps."}
  end

  defp answers(step, input) when is_map(input) do
    fields = step["fields"] || []
    unknown = Map.keys(input) -- Enum.map(fields, & &1["key"])

    if unknown != [] do
      {:error, "Unknown workflow field: #{Enum.map_join(unknown, ", ", &inspect/1)}."}
    else
      Enum.reduce_while(fields, {:ok, %{}}, fn f, {:ok, acc} ->
        v = input[f["key"]]
        required = f["required"] == true

        cond do
          required and missing_answer?(f, v) ->
            {:halt, {:error, "#{f["label"]} is required."}}

          not valid_answer?(f, v) ->
            {:halt, {:error, "#{f["label"]} has an invalid value."}}

          true ->
            {:cont,
             {:ok,
              Map.put(
                acc,
                f["key"],
                if(f["type"] == "checkbox", do: v in [true, "true", "on"], else: v || "")
              )}}
        end
      end)
    end
  end

  defp answers(_, _), do: {:error, "Field answers must be an object."}

  defp missing_answer?(%{"type" => "checkbox"}, value), do: value not in [true, "true", "on"]

  defp missing_answer?(_, value),
    do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp valid_answer?(%{"type" => "checkbox"}, value),
    do: value in [true, false, "true", "false", "on", nil]

  defp valid_answer?(%{"type" => "number"}, value) when is_number(value) or value in [nil, ""],
    do: true

  defp valid_answer?(%{"type" => "number"}, value) when is_binary(value),
    do: match?({_, ""}, Float.parse(value))

  defp valid_answer?(%{"type" => "number"}, _), do: false

  defp valid_answer?(%{"type" => "select"} = field, value),
    do: value in (field["options"] || []) or value in [nil, ""]

  defp valid_answer?(_, value), do: is_binary(value) or is_nil(value)

  defp permit(principal, capability, workspace, type \\ nil) do
    case Policy.authorize(principal, capability, %{workspace: workspace, ticket_type: type}) do
      :allow -> :ok
      {:deny, reason} -> {:error, reason}
    end
  end

  defp write(workspace, fun) do
    WorkspaceLock.with_lock(workspace, fn -> Store.transaction(workspace, fun) end)
    |> case do
      {:ok, {:denied, reason}} -> {:error, reason}
      result -> result
    end
  end

  defp persist(tx, workspace, table, row, principal, reason, diff) do
    with {:ok, stored} <- Store.put(tx, table, row),
         {:ok, _} <-
           Audit.append(tx, workspace, %{
             subject: row["id"],
             subject_table: to_string(table),
             actor: Principal.audit_actor(principal),
             reason: reason,
             diff: diff,
             from_state: nil,
             to_state: row["status"] || "configured",
             correlation_id: nil
           }) do
      {:ok, stored}
    end
  end

  defp fetch(tx, table, id) do
    case Store.fetch(tx, table, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} when table == :workflow_run -> restore_approved_outputs(tx, row)
      result -> result
    end
  end

  defp restore_approved_outputs(tx, row) do
    if Map.has_key?(row["data"], "approved_outputs") do
      {:ok, row}
    else
      # Old outputs may already be overwritten by a new proposal; only approval audit is evidence.
      with {:ok, events} <-
             Store.list(tx, :audit_event, %{
               where: [subject: row["id"], subject_table: "workflow_run"],
               order_by: [sequence: :asc]
             }) do
        outputs =
          events
          |> Enum.filter(
            &(&1["reason"] in ["Human approved workflow step", "Workflow step completed"])
          )
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {event, visit} ->
            output = event["diff"]["accepted_ai_output"]

            if event["reason"] == "Human approved workflow step" and is_map(output) and
                 text?(output["text"]) do
              [
                approved_entry(
                  output,
                  event["diff"]["step"],
                  visit,
                  event["actor_id"],
                  event["timestamp"]
                )
              ]
            else
              []
            end
          end)

        {:ok, put_in(row, ["data", "approved_outputs"], outputs)}
      end
    end
  end

  defp existing(_, _, nil), do: {:ok, nil}
  defp existing(tx, table, id), do: fetch(tx, table, id)
  defp revision(nil, _), do: :ok

  defp revision(row, expected) when is_integer(expected) do
    if row["revision"] == expected, do: :ok, else: {:error, :revision_conflict}
  end

  defp revision(_, _), do: {:error, :revision_conflict}

  defp identifier(prefix),
    do: prefix <> "_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

  defp text?(v), do: is_binary(v) and String.trim(v) != ""
  defp optional_text?(v), do: is_nil(v) or is_binary(v)
  defp identifier?(v), do: is_binary(v) and Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9_]{0,63}\z/, v)
end
