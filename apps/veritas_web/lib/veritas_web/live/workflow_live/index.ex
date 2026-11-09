defmodule Veritas.Web.WorkflowLive.Index do
  use Veritas.Web, :live_view
  alias Veritas.Agentic.Runner
  alias Veritas.Core.{Policy, Tickets, Workflows}
  import Veritas.Web.WorkflowLive.Components
  alias Veritas.Store.Error

  def mount(_params, _session, socket) do
    workspace = socket.assigns.principal_workspace

    {:ok,
     assign(socket,
       page_title: "Workflows",
       workspace: workspace,
       workflows: [],
       workflow: nil,
       definition: Workflows.template(),
       selected: "intake",
       busy: false,
       models: [],
       model: "",
       policy_envelope: nil,
       policy_form: policy_form(%{}),
       policy_validation: nil,
       surface_error: nil,
       can_edit_policy: socket.assigns.principal.kind == :human and :platform_admin in socket.assigns.principal.roles,
       can_edit:
         Policy.permitted?(socket.assigns.principal, "account:administrate", %{
           workspace: workspace
         })
     ) |> load_policy()}
  end

  def handle_params(params, _uri, socket) do
    socket = load_list(socket)

    case params["id"] do
      nil ->
        {:noreply, assign(socket, workflow: nil, editing: false)}

      "new" ->
        {:noreply,
         assign(socket,
           workflow: nil,
           definition: Workflows.template(),
           selected: "intake",
           editing: true
         )}

      id ->
        case Workflows.get(socket.assigns.workspace, id, socket.assigns.principal) do
          {:ok, workflow} ->
            definition = workflow["definition"]
            selected = hd(definition["steps"])["id"]

            {:noreply,
             assign(socket,
               workflow: workflow,
               definition: definition,
               selected: selected,
               editing: true
             )}

          {:error, reason} ->
            {:noreply,
             socket |> put_flash(:error, Error.public(reason).message) |> push_patch(to: ~p"/workflows")}
        end
    end
  end

  def handle_event("metadata", params, socket) do
    definition =
      Map.merge(socket.assigns.definition, Map.take(params, ~w(name description ticket_type)))

    definition =
      if definition["ticket_type"] != socket.assigns.definition["ticket_type"],
        do: update_in(definition["steps"], &Enum.map(&1, fn s -> Map.put(s, "state", "") end)),
        else: definition

    {:noreply, assign(socket, :definition, definition)}
  end

  def handle_event("select-step", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :selected, id)}

  def handle_event("step", %{"step" => params}, socket) do
    old = selected(socket.assigns)
    fields = params["fields"] || %{}

    fields =
      fields
      |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
      |> Enum.map(fn {_k, f} ->
        f
        |> Map.put("required", f["required"] in [true, "true"])
        |> Map.put("options", split(f["options_text"]))
        |> Map.delete("options_text")
        |> then(fn field -> if field["binding"] in [nil, ""], do: Map.delete(field, "binding"), else: field end)
      end)

    changed =
      old
      |> Map.merge(Map.take(params, ~w(name kind phase instructions state model)))
      |> Map.put("fields", fields)
      |> Map.put("next", params["next"] |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])))

    {:noreply, replace_step(socket, changed)}
  end

  def handle_event("add-step", _, socket) do
    step = selected(socket.assigns)
    id = "step_" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    added = %{
      "id" => id,
      "name" => "New step",
      "kind" => "manual",
      "phase" => "processing",
      "instructions" => "",
      "fields" => [],
      "next" => step["next"]
    }

    steps =
      Enum.flat_map(socket.assigns.definition["steps"], fn s ->
        if s["id"] == step["id"], do: [Map.put(s, "next", [id]), added], else: [s]
      end)

    {:noreply,
     socket
     |> assign(:definition, Map.put(socket.assigns.definition, "steps", steps))
     |> assign(:selected, id)}
  end

  def handle_event("remove-step", _, socket) do
    step = selected(socket.assigns)

    if step["kind"] == "intake" do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Keep the intake step; edit its fields and instructions instead."
       )}
    else
      steps =
        socket.assigns.definition["steps"]
        |> Enum.reject(&(&1["id"] == step["id"]))
        |> Enum.map(fn s ->
          Map.update!(s, "next", fn ns ->
            Enum.flat_map(ns, &if(&1 == step["id"], do: step["next"], else: [&1])) |> Enum.uniq()
          end)
        end)

      {:noreply,
       socket
       |> assign(:definition, Map.put(socket.assigns.definition, "steps", steps))
       |> assign(:selected, hd(steps)["id"])}
    end
  end

  def handle_event("add-field", _, socket) do
    step = selected(socket.assigns)

    # A removed field frees its position, not its identifier: count up past every key still in use.
    keys = MapSet.new(step["fields"] || [], & &1["key"])

    n =
      Enum.find(
        Stream.iterate(length(step["fields"] || []) + 1, &(&1 + 1)),
        &(not MapSet.member?(keys, "field_#{&1}"))
      )

    field = %{
      "key" => "field_#{n}",
      "label" => "New field",
      "type" => "text",
      "required" => false,
      "options" => []
    }

    {:noreply, replace_step(socket, Map.update(step, "fields", [field], &(&1 ++ [field])))}
  end

  def handle_event("remove-field", %{"index" => index}, socket) do
    step = selected(socket.assigns)

    {:noreply,
     replace_step(
       socket,
       Map.update!(step, "fields", &List.delete_at(&1, String.to_integer(index)))
     )}
  end

  def handle_event("policy-change", %{"policy" => form}, socket),
    do: {:noreply, assign(socket, policy_form: form, policy_validation: nil)}

  def handle_event("policy-add", params, socket) do
    path = case params["kind"] do
      "calendar" -> ["calendars"]
      "weekly" -> ["calendars", params["calendar"], "weekly", params["day"], "intervals"]
      "date" -> ["calendars", params["calendar"], "nonworking_dates"]
      "exception" -> ["calendars", params["calendar"], "exceptions"]
      "exception-interval" -> ["calendars", params["calendar"], "exceptions", params["row"], "intervals"]
      _ -> nil
    end
    if socket.assigns.can_edit_policy and path,
      do: {:noreply, assign(socket, :policy_form, add_policy_row(socket.assigns.policy_form, path, %{}))},
      else: {:noreply, socket}
  end

  def handle_event("policy-action", %{"policy" => form} = params, socket) do
    socket = assign(socket, :policy_form, form)
    %{workspace: workspace, principal: principal, policy_envelope: envelope} = socket.assigns
    result = with {:ok, document} <- policy_document(form) do
      case params["action"] do
        "validate" -> Tickets.validate_incident_policy(workspace, document, principal)
        "save" when not is_nil(envelope) ->
          Tickets.save_incident_policy(workspace, document, principal, envelope.policy_revision)
        _ -> {:error, :invalid_request}
      end
    end
    case result do
      {:ok, %{document: _} = validation} ->
        {:noreply, assign(socket, policy_validation: validation, surface_error: nil)}
      {:ok, envelope} ->
        {:noreply, socket |> assign(policy_envelope: envelope, surface_error: nil,
          policy_validation: nil) |> put_flash(:info, "Incident policy draft saved; not published.")}
      {:error, reason} -> {:noreply, assign(socket, :surface_error, Error.public(reason))}
    end
  end

  def handle_event("policy-publish", params, socket) do
    envelope = socket.assigns.policy_envelope
    case Tickets.publish_incident_policy(socket.assigns.workspace, socket.assigns.principal,
           envelope && envelope.policy_revision, approve: params["approve"] == "true",
           expected_policy_version: envelope && envelope.active_version) do
      {:ok, updated} ->
        {:noreply, socket |> assign(policy_envelope: updated, surface_error: nil,
          policy_validation: nil) |> put_flash(:info, "Saved Incident policy published. Existing clocks retain their bindings.")}
      {:error, reason} -> {:noreply, assign(socket, :surface_error, Error.public(reason))}
    end
  end

  def handle_event("policy-reload", _, socket), do: {:noreply, load_policy(socket)}

  def handle_event("save", _, socket), do: save(socket, false)
  def handle_event("publish", _, socket), do: save(socket, true)

  def handle_event("models", _, socket) do
    workspace = socket.assigns.workspace
    {:noreply, start_async(socket, :models, fn -> Runner.models(workspace) end)}
  end

  def handle_event("generate", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("generate", params, socket) do
    if socket.assigns.can_edit do
      workspace = socket.assigns.workspace
      principal = socket.assigns.principal
      type = socket.assigns.definition["ticket_type"]
      prompt = params["prompt"] || ""
      model = present(params["model"])

      generate = fn ->
        Workflows.generate(workspace, prompt, type, principal, model: model, timeout: 90_000)
      end

      {:noreply, socket |> assign(:busy, true) |> start_async(:generate, generate)}
    else
      {:noreply, put_flash(socket, :error, "A Platform Admin manages workflow definitions.")}
    end
  end

  def handle_async(:models, {:ok, {:ok, models}}, socket),
    do: {:noreply, assign(socket, :models, Enum.sort_by(models, & &1.id))}

  def handle_async(:generate, {:ok, {:ok, definition}}, socket),
    do:
      {:noreply,
       socket
       |> assign(definition: definition, selected: hd(definition["steps"])["id"], busy: false)
       |> put_flash(
         :info,
         "AI drafted the workflow. Review and edit it, then publish when ready."
       )}

  def handle_async(_name, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(:busy, false) |> put_flash(:error, Error.public(reason).message)}

  def handle_async(_name, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(:busy, false)
       |> put_flash(:error, "The AI request stopped. Your draft is still here; try again.")}

  defp save(socket, publish?) do
    current = socket.assigns.workflow

    case Workflows.save(
           socket.assigns.workspace,
           current && current["id"],
           socket.assigns.definition,
           socket.assigns.principal,
           expected_revision: current && current["revision"]
         ) do
      {:ok, saved} ->
        # The draft is stored even when publication is refused below. The editor
        # holds it, so a corrected retry saves the same workflow at its new revision.
        socket = assign(socket, :workflow, saved)

        result =
          if publish?,
            do:
              Workflows.publish(
                socket.assigns.workspace,
                saved["id"],
                saved["revision"],
                socket.assigns.principal
              ),
            else: {:ok, saved}

        case result do
          {:ok, workflow} ->
            message =
              if publish?,
                do: "Workflow published. New tickets can use it now.",
                else: "Draft saved."

            socket = socket |> assign(:workflow, workflow) |> put_flash(:info, message)
            {:noreply, push_patch(socket, to: ~p"/workflows/#{workflow["id"]}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Error.public(reason).message)}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Error.public(reason).message)}
    end
  end

  defp load_policy(socket) do
    case Tickets.incident_policy(socket.assigns.workspace, socket.assigns.principal) do
      {:ok, envelope} ->
        document = if envelope.draft, do: envelope.draft.document, else: envelope.active || %{}
        assign(socket, policy_envelope: envelope, policy_form: policy_form(document),
          policy_validation: nil, surface_error: nil)
      {:error, reason} -> assign(socket, :surface_error, Error.public(reason))
    end
  end

  defp load_list(socket) do
    case Workflows.list(socket.assigns.workspace, socket.assigns.principal) do
      {:ok, rows} ->
        assign(socket, :workflows, rows)

      {:error, reason} ->
        socket |> assign(:workflows, []) |> put_flash(:error, Error.public(reason).message)
    end
  end

  defp selected(assigns),
    do:
      Enum.find(assigns.definition["steps"], &(&1["id"] == assigns.selected)) ||
        hd(assigns.definition["steps"])

  defp replace_step(socket, changed),
    do:
      assign(
        socket,
        :definition,
        Map.update!(
          socket.assigns.definition,
          "steps",
          &Enum.map(&1, fn s -> if s["id"] == changed["id"], do: changed, else: s end)
        )
      )

  defp split(v),
    do:
      (v || "")
      |> String.split([",", "\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp present(v) when v in [nil, ""], do: nil
  defp present(v), do: v

  def render(assigns) do
    assigns = assign(assigns, :step, selected(assigns))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <main class="mx-auto max-w-7xl px-6 py-8">
      <header class="mb-7 flex flex-wrap items-start justify-between gap-4">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-[0.15em] text-primary">
            Service operations
          </p><h1 class="text-3xl font-semibold tracking-tight">Workflows</h1><p class="mt-2 text-sm text-base-content/60">
            Design the intake, the work and what happens afterward.
          </p>
        </div>
        <.link :if={@can_edit} patch={~p"/workflows/new"} class="btn btn-primary btn-sm">Create workflow</.link>
      </header>
      <div :if={!@editing} class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <article :for={workflow <- @workflows} class="v-panel flex flex-col rounded-xl p-5">
          <div class="mb-4 flex items-center justify-between">
            <span class="badge badge-outline text-xs">{String.replace(
              workflow["ticket_type"],
              "_",
              " "
            )}</span><span class={[
              "text-xs",
              if(workflow["published_revision"] > 0, do: "text-success", else: "text-base-content/50")
            ]}>{if workflow["published_revision"] > 0,
              do: "Published · v#{workflow["published_revision"]}",
              else: "Draft"}</span>
          </div>
          <h2 class="text-lg font-semibold">{workflow["name"]}</h2><p class="mt-2 flex-1 text-sm text-base-content/60">
            {workflow["definition"]["description"]}
          </p>
          <p class="mt-4 text-xs text-base-content/50">
            {length(workflow["definition"]["steps"])} steps · intake → processing → follow-up
          </p>
          <div class="mt-5 flex gap-2">
            <.link patch={~p"/workflows/#{workflow["id"]}"} class="btn btn-sm btn-ghost">Open editor</.link><.link
              :if={workflow["published_revision"] > 0}
              navigate={~p"/workflows/#{workflow["id"]}/intake"}
              class="btn btn-primary btn-sm"
            >Create ticket</.link>
          </div>
        </article>
        <div
          :if={@workflows == []}
          class="v-panel col-span-full rounded-xl border-dashed px-8 py-16 text-center"
        >
          <h2 class="text-lg font-semibold">Your team's way of working, made explicit.</h2><p class="mx-auto mt-2 max-w-lg text-sm text-base-content/60">
            Start with an incident response flow, then edit its fields, human steps, AI instructions, approvals and follow-up.
          </p><.link :if={@can_edit} patch={~p"/workflows/new"} class="btn btn-primary btn-sm mt-6">Build your first workflow</.link>
        </div>
      </div>

      <div :if={@editing}>
        <div class="mb-5 flex flex-wrap items-center justify-between gap-3">
          <.link patch={~p"/workflows"} class="text-sm text-base-content/60 hover:text-primary">← All workflows</.link><div class="flex items-center gap-2">
            <span class="mr-2 text-xs text-base-content/50">{if @workflow,
              do: "Draft v#{@workflow["revision"]}",
              else: "Unsaved draft"}</span><button
              :if={@can_edit}
              id="workflow-save"
              phx-click="save"
              class="btn btn-sm btn-outline"
            >Save draft</button><button
              :if={@can_edit}
              id="workflow-publish"
              phx-click="publish"
              class="btn btn-primary btn-sm"
            >Publish workflow</button><.link
              :if={@workflow && @workflow["published_revision"] > 0}
              navigate={~p"/workflows/#{@workflow["id"]}/intake"}
              class="btn btn-sm"
            >Create ticket →</.link>
          </div>
        </div>
        <form
          id="workflow-metadata"
          phx-change="metadata"
          class="v-panel mb-5 grid gap-4 rounded-xl p-5 md:grid-cols-[2fr_1fr]"
        >
          <label class="text-xs font-medium">Workflow name<input
            name="name"
            value={@definition["name"]}
            class="input input-bordered mt-1 w-full"
            disabled={!@can_edit}
          /></label><label class="text-xs font-medium">Ticket type<select
            name="ticket_type"
            class="select select-bordered mt-1 w-full"
            disabled={!@can_edit}
          ><option
            :for={type <- Veritas.Core.Tickets.ticket_types()}
            value={type}
            selected={type == @definition["ticket_type"]}
          >
            {String.replace(type, "_", " ")}
          </option></select></label>
          <label class="text-xs font-medium md:col-span-2">Purpose<input
            name="description"
            value={@definition["description"]}
            class="input input-bordered input-sm mt-1 w-full"
            disabled={!@can_edit}
          /></label>
        </form>
        <div class="grid items-start gap-5 lg:grid-cols-[260px_minmax(0,1fr)]">
          <aside class="v-panel rounded-xl p-3">
            <p class="px-2 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/50">
              The flow
            </p><ol class="space-y-1">
              <li :for={{step, i} <- Enum.with_index(@definition["steps"])}>
                <button
                  phx-click="select-step"
                  phx-value-id={step["id"]}
                  class={[
                    "flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left",
                    if(step["id"] == @selected,
                      do: "bg-primary/10 text-primary",
                      else: "hover:bg-base-200"
                    )
                  ]}
                ><span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full border text-xs">{i +
                  1}</span><span><span class="block text-sm font-semibold">{step["name"]}</span><span class="text-[10px] uppercase tracking-wide opacity-60">{String.replace(
                  step["phase"],
                  "_",
                  " "
                )} · {step["kind"]}</span></span></button>
              </li>
            </ol><button
              :if={@can_edit}
              phx-click="add-step"
              id="workflow-add-step"
              class="btn btn-ghost btn-sm mt-3 w-full"
            >+ Add step after selected</button>
          </aside>
          <section class="v-panel min-w-0 rounded-xl p-5">
            <div class="mb-5 flex items-center justify-between">
              <div>
                <p class="font-mono text-[10px] text-base-content/40">{@step["id"]}</p><h2 class="text-lg font-semibold">
                  Edit step
                </h2>
              </div><button
                :if={@can_edit && @step["kind"] != "intake"}
                phx-click="remove-step"
                class="btn btn-ghost btn-xs text-error"
              >Remove step</button>
            </div>
            <form id="workflow-step" phx-change="step" class="space-y-5">
              <fieldset disabled={!@can_edit} class="space-y-5">
                <label class="block text-xs font-medium">Step name<input
                  name="step[name]"
                  value={@step["name"]}
                  class="input input-bordered mt-1 w-full"
                /></label>
                <div class="grid grid-cols-2 gap-4">
                  <label class="text-xs font-medium">Kind<select
                    name="step[kind]"
                    class="select select-bordered mt-1 w-full"
                  ><option
                    :for={
                      kind <-
                        if(@step["kind"] == "intake", do: ["intake"], else: ~w(manual ai approval))
                    }
                    value={kind}
                    selected={kind == @step["kind"]}
                  >
                    {kind}
                  </option></select></label><label class="text-xs font-medium">Phase<select
                    name="step[phase]"
                    class="select select-bordered mt-1 w-full"
                  ><option
                    :for={phase <- ~w(intake processing after_action)}
                    value={phase}
                    selected={phase == @step["phase"]}
                  >
                    {String.replace(phase, "_", " ")}
                  </option></select></label>
                </div>
                <label class="block text-xs font-medium">{if @step["kind"] == "ai",
                  do: "AI instructions",
                  else: "Instructions"}<textarea
                  name="step[instructions]"
                  rows="4"
                  class="textarea textarea-bordered mt-1 w-full"
                >{@step["instructions"]}</textarea></label>
                <label :if={@step["kind"] == "ai"} class="block text-xs font-medium">Model for this step<div class="mt-1 flex gap-2">
                  <input
                    name="step[model]"
                    value={@step["model"] || ""}
                    list="workflow-model-catalogue"
                    placeholder="Use the provider’s configured model"
                    class="input input-bordered input-sm w-full"
                  /><button
                    type="button"
                    id="workflow-step-load-models"
                    phx-click="models"
                    class="btn btn-ghost btn-sm"
                  >Load models</button>
                </div><datalist id="workflow-model-catalogue"><option
                  :for={m <- @models}
                  value={m.id}
                /></datalist></label>
                <div :if={@step["kind"] != "intake"} class="grid gap-4 md:grid-cols-2">
                  <label class="text-xs font-medium">Ticket state on completion<input
                    name="step[state]"
                    value={@step["state"] || ""}
                    placeholder="Leave unchanged"
                    class="input input-bordered input-sm mt-1 w-full"
                  /><span class="mt-1 block text-[11px] font-normal text-base-content/50">Existing lifecycle and approval rules still apply.</span></label><label class="text-xs font-medium">Continue to<select
                    name="step[next][]"
                    multiple
                    class="select select-bordered mt-1 h-auto min-h-24 w-full"
                  ><option
                    :for={
                      choice <-
                        Enum.filter(
                          @definition["steps"],
                          &(&1["id"] != @step["id"] && &1["kind"] != "intake")
                        )
                    }
                    value={choice["id"]}
                    selected={choice["id"] in @step["next"]}
                  >
                    {choice["name"]} ({choice["id"]})
                  </option></select><span class="mt-1 block text-[11px] font-normal text-base-content/50">Multiple selections create a branch. No selection finishes the flow.</span></label>
                </div>
                <input
                  :for={next <- @step["next"]}
                  :if={@step["kind"] == "intake"}
                  type="hidden"
                  name="step[next][]"
                  value={next}
                />
                <div class="border-t border-base-300 pt-5">
                  <h3 class="text-sm font-semibold">Fields to collect</h3><p class="mt-1 text-xs text-base-content/50">
                    These fields appear when someone reaches this step.
                  </p>
                  <div
                    :for={{field, i} <- Enum.with_index(@step["fields"] || [])}
                    class="mt-3 rounded-lg border border-base-300 p-3"
                  >
                    <div class="grid gap-3 sm:grid-cols-2">
                      <label class="text-xs">Label<input
                        name={"step[fields][#{i}][label]"}
                        value={field["label"]}
                        class="input input-bordered input-sm mt-1 w-full"
                      /></label><label class="text-xs">Field identifier<input
                        name={"step[fields][#{i}][key]"}
                        value={field["key"]}
                        class="input input-bordered input-sm mt-1 w-full font-mono"
                      /></label><label class="text-xs">Type<select
                        name={"step[fields][#{i}][type]"}
                        class="select select-bordered select-sm mt-1 w-full"
                      ><option
                        :for={type <- ~w(text textarea number select checkbox)}
                        value={type}
                        selected={type == field["type"]}
                      >
                        {type}
                      </option></select></label><label class="flex items-center gap-2 text-xs"><input
                        type="hidden"
                        name={"step[fields][#{i}][required]"}
                        value="false"
                      /><input
                        type="checkbox"
                        name={"step[fields][#{i}][required]"}
                        value="true"
                        checked={field["required"]}
                        class="checkbox checkbox-sm"
                      />Required</label><label
                        :if={field["type"] == "select"}
                        class="text-xs sm:col-span-2"
                      >Choices, separated by commas<input
                        name={"step[fields][#{i}][options_text]"}
                        value={Enum.join(field["options"] || [], ", ")}
                        class="input input-bordered input-sm mt-1 w-full"
                      /></label>
                      <label :if={@definition["ticket_type"] == "incident"} class="text-xs sm:col-span-2">Semantic Incident binding
                        <select name={"step[fields][#{i}][binding]"} class="select select-bordered mt-1 w-full">
                          <option value="">Extension answer only (unbound)</option>
                          <option :for={binding <- Veritas.Core.Tickets.Incident.fields()} value={binding} selected={field["binding"] == binding}>{binding}</option>
                        </select>
                        <span class="block text-[11px] text-base-content/50">Explicit only; never inferred from the label or identifier. Structured bindings use textarea definitions with typed runtime controls.</span>
                      </label>
                    </div><button
                      type="button"
                      phx-click="remove-field"
                      phx-value-index={i}
                      class="mt-2 text-xs text-error"
                    >Remove field</button>
                  </div>
                </div>
              </fieldset>
            </form>
            <button
              :if={@can_edit}
              phx-click="add-field"
              id="workflow-add-field"
              class="btn btn-outline btn-sm mt-4"
            >+ Add field</button>
          </section>
        </div>
        <section :if={@can_edit} class="v-panel mt-5 rounded-xl p-5">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-sm font-semibold">Design with AI</h2><p class="mt-1 text-xs text-base-content/50">
                Describe the process. AI proposes an editable draft; you decide what gets published.
              </p>
            </div><button
              type="button"
              id="workflow-load-models"
              phx-click="models"
              class="btn btn-ghost btn-xs"
            >Load available models</button>
          </div><form id="workflow-generate" phx-submit="generate" class="mt-4 space-y-3">
            <textarea
              name="prompt"
              rows="3"
              required
              placeholder="For a production outage: collect the service and impact, have AI triage it, require investigation evidence, verify recovery, then draft an after-action review…"
              class="textarea textarea-bordered w-full"
            /><div class="flex flex-wrap justify-end gap-2">
              <select name="model" class="select select-bordered select-sm"><option value="">
                Provider's configured model
              </option><option :for={m <- @models} value={m.id}>{m.id}</option></select><button
                type="submit"
                disabled={@busy}
                class="btn btn-primary btn-sm"
              >{if @busy, do: "Drafting…", else: "Draft workflow with AI"}</button>
            </div>
          </form>
        </section>
      </div>
      <.public_error error={@surface_error} />
      <.policy_editor :if={@policy_envelope} form={@policy_form} envelope={@policy_envelope}
        can_edit={@can_edit_policy} validation={@policy_validation} />
    </main>
    """
  end
end
