defmodule Veritas.Web.GraphQL.WorkflowTypes do
  @moduledoc "Authenticated GraphQL adapters for the shared workflow service."
  use Absinthe.Schema.Notation
  alias Veritas.Core.{Tickets, Workflows}
  alias Veritas.Store.Error

  object :workflow_record do
    field(:id, :string)
    field(:name, :string)
    field(:ticket_type, :string)
    field(:revision, :integer)
    field(:published_revision, :integer)
    field(:definition, :json_map)
    field(:published_definition, :json_map)
  end

  object :workflow_execution do
    field(:id, :string)
    field(:ticket, :string)
    field(:workflow, :string)
    field(:workflow_revision, :integer)
    field(:revision, :integer)
    field(:status, :string)
    field(:definition, :json_map)
    field(:data, :json_map)
  end

  object :workflow_queries do
    field :incident_domain, :json_map do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      resolve(fn _, args, info ->
        respond(Tickets.read_domain(args.workspace, args.id, info.context[:principal]), & &1)
      end)
    end

    field :incident_policy, :json_map do
      arg(:workspace, non_null(:string))
      resolve(fn _, args, info ->
        respond(Tickets.incident_policy(args.workspace, info.context[:principal]), & &1)
      end)
    end

    field :workflows, list_of(:workflow_record) do
      arg(:workspace, non_null(:string))
      complexity(fn _, child -> 200 * (child + 1) end)

      resolve(fn _, args, info ->
        respond(
          Workflows.list(args.workspace, info.context[:principal]),
          &Enum.map(&1, fn row -> workflow(row) end)
        )
      end)
    end

    field :workflow, :workflow_record do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))

      resolve(fn _, args, info ->
        respond(Workflows.get(args.workspace, args.id, info.context[:principal]), &workflow/1)
      end)
    end

    field :ticket_workflow, :workflow_execution do
      arg(:workspace, non_null(:string))
      arg(:ticket_id, non_null(:string))

      resolve(fn _, args, info ->
        respond(
          Workflows.run(args.workspace, args.ticket_id, info.context[:principal]),
          &execution/1
        )
      end)
    end
  end

  object :workflow_mutations do
    field :update_incident_domain, :json_map do
      arg(:workspace, non_null(:string))
      arg(:ticket_id, non_null(:string))
      arg(:fields_json, non_null(:string))
      arg(:expected_revision, :integer)
      arg(:expected_domain_revision, :integer)
      arg(:expected_policy_version, :string)
      resolve(fn _, args, info ->
        with {:ok, fields} <- decode(args.fields_json) do
          respond(Tickets.update_domain(args.workspace, args.ticket_id, fields,
            info.context[:principal], domain_opts(args)), & &1)
        end
      end)
    end

    field :validate_incident_policy, :json_map do
      arg(:workspace, non_null(:string))
      arg(:document_json, non_null(:string))
      resolve(fn _, args, info ->
        with {:ok, document} <- decode(args.document_json) do
          respond(Tickets.validate_incident_policy(args.workspace, document, info.context[:principal]), & &1)
        end
      end)
    end

    field :save_incident_policy, :json_map do
      arg(:workspace, non_null(:string))
      arg(:document_json, non_null(:string))
      arg(:expected_policy_revision, :integer)
      resolve(fn _, args, info ->
        with true <- Map.has_key?(args, :expected_policy_revision) || {:error, safe_error(:invalid_request)},
             {:ok, document} <- decode(args.document_json) do
          respond(Tickets.save_incident_policy(args.workspace, document,
            info.context[:principal], args.expected_policy_revision), & &1)
        end
      end)
    end

    field :publish_incident_policy, :json_map do
      arg(:workspace, non_null(:string))
      arg(:expected_policy_revision, non_null(:integer))
      arg(:expected_policy_version, :string)
      arg(:approve, non_null(:boolean))
      resolve(fn _, args, info ->
        respond(Tickets.publish_incident_policy(args.workspace, info.context[:principal],
          args.expected_policy_revision, domain_opts(args) ++ [approve: args.approve]), & &1)
      end)
    end

    @desc "Save an editable workflow draft. definitionJson is a serialized JSON object. Existing drafts require expectedRevision."
    field :save_workflow, :workflow_record do
      arg(:workspace, non_null(:string))
      arg(:id, :string)
      arg(:definition_json, non_null(:string))
      arg(:expected_revision, :integer)

      resolve(fn _, args, info ->
        with {:ok, definition} <- decode(args.definition_json) do
          respond(
            Workflows.save(args.workspace, args[:id], definition, info.context[:principal],
              expected_revision: args[:expected_revision]
            ),
            &workflow/1
          )
        end
      end)
    end

    field :publish_workflow, :workflow_record do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      arg(:expected_revision, non_null(:integer))

      resolve(fn _, args, info ->
        respond(
          Workflows.publish(
            args.workspace,
            args.id,
            args.expected_revision,
            info.context[:principal]
          ),
          &workflow/1
        )
      end)
    end

    field :start_workflow, :workflow_execution do
      arg(:workspace, non_null(:string))
      arg(:id, non_null(:string))
      arg(:input_json, non_null(:string))

      resolve(fn _, args, info ->
        with {:ok, input} <- decode(args.input_json) do
          respond(
            Workflows.start(args.workspace, args.id, input, info.context[:principal]),
            &execution/1
          )
        end
      end)
    end

    field :complete_workflow_step, :workflow_execution do
      arg(:workspace, non_null(:string))
      arg(:ticket_id, non_null(:string))
      arg(:answers_json, :string, default_value: "{}")
      arg(:expected_revision, non_null(:integer))
      arg(:next_step, :string)
      arg(:approve, :boolean, default_value: false)
      arg(:domain_fields_json, :string, default_value: "{}")
      arg(:expected_domain_revision, :integer)
      arg(:expected_policy_version, :string)

      resolve(fn _, args, info ->
        with {:ok, answers} <- decode(args.answers_json),
             {:ok, fields} <- decode(args.domain_fields_json) do
          respond(
            Workflows.complete(args.workspace, args.ticket_id, answers, info.context[:principal],
              domain_opts(args) ++ [domain_fields: fields, next: args[:next_step], approve: args.approve]
            ),
            &execution/1
          )
        end
      end)
    end

    field :draft_workflow_step, :workflow_execution do
      arg(:workspace, non_null(:string))
      arg(:ticket_id, non_null(:string))
      arg(:model, :string)

      resolve(fn _, args, info ->
        respond(
          Workflows.draft(args.workspace, args.ticket_id, info.context[:principal],
            model: args[:model]
          ),
          &execution/1
        )
      end)
    end

    field :generate_workflow, :json_map do
      arg(:workspace, non_null(:string))
      arg(:prompt, non_null(:string))
      arg(:ticket_type, non_null(:string))
      arg(:model, :string)

      resolve(fn _, args, info ->
        respond(
          Workflows.generate(
            args.workspace,
            args.prompt,
            args.ticket_type,
            info.context[:principal],
            model: args[:model]
          ),
          & &1
        )
      end)
    end
  end

  defp decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = value} -> {:ok, value}
      _ -> {:error, safe_error(:invalid_request)}
    end
  end

  defp decode(_), do: {:error, safe_error(:invalid_request)}

  defp domain_opts(args), do: args |> Map.take([:expected_revision,
    :expected_domain_revision, :expected_policy_version]) |> Map.to_list()

  defp safe_error(reason) do
    safe = Error.public(reason)
    %{message: safe.message, extensions: Map.delete(safe, :message)}
  end

  defp respond({:ok, value}, convert), do: {:ok, convert.(value)}
  defp respond({:error, reason}, _), do: {:error, safe_error(reason)}

  defp workflow(row),
    do: %{
      id: row["id"],
      name: row["name"],
      ticket_type: row["ticket_type"],
      revision: row["revision"],
      published_revision: row["published_revision"],
      definition: row["definition"],
      published_definition: row["published_definition"]
    }

  defp execution(row),
    do: %{
      id: row["id"],
      ticket: row["ticket"],
      workflow: row["workflow"],
      workflow_revision: row["workflow_revision"],
      revision: row["revision"],
      status: row["status"],
      definition: row["definition"],
      data: row["data"]
    }
end
