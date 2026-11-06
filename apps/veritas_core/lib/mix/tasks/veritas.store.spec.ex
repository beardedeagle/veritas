defmodule Mix.Tasks.Veritas.Store.Spec do
  @moduledoc """
  Runs the data-access conformance suite against a live Adapter.

      mix veritas.store.spec --workspace veritas_spec
      mix veritas.store.spec --workspace veritas_spec --adapter MyApp.Store.Postgres
      mix veritas.store.spec --keep
      mix veritas.store.spec --json

  The suite is the contract from `docs/32` made executable: it checks the
  obligations a store Adapter must hold — atomicity, ordering, Workspace
  isolation, durability, the Audit Log chain, the change stream, and loud
  failure — against the store that is actually installed.

  It writes to a scratch Workspace and **removes it afterwards**, so it is
  safe to run against a live store. Pass `--keep` to leave the Workspace
  behind for inspection.

  The exit code is 0 when every obligation holds and 1 when one does not.
  """

  use Mix.Task

  alias Veritas.Store.Spec

  @shortdoc "Check the data-access Adapter against the store contract"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [workspace: :string, adapter: :string, json: :boolean, keep: :boolean],
        aliases: [w: :workspace]
      )

    workspace = opts[:workspace] || "veritas_spec"

    adapter =
      case opts[:adapter] do
        nil ->
          nil

        name ->
          name |> String.split(".") |> Enum.map(&String.to_atom/1) |> Module.concat()
      end

    {results, ok?} = Spec.run(workspace: workspace, adapter: adapter)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(%{spec: results, ok: ok?}, pretty: true))
    else
      Mix.shell().info(Spec.format(results))
    end

    unless opts[:keep], do: remove_workspace(workspace)

    if ok? do
      exit(0)
    else
      Mix.shell().error("the store adapter does not satisfy the contract")
      exit(1)
    end
  end

  # The scratch Workspace is removed so that a conformance run leaves nothing
  # behind on a live store. Removal is a root-context operation, so it is
  # issued directly rather than through the Adapter.
  #
  # The database inside the namespace is dropped first — a namespace cannot be
  # removed while a database inside it still exists — and then the namespace.
  # The two statements are issued separately, so a failure in the first cannot
  # stop the second, and removing a Workspace that is already gone is not an
  # error: the removal is idempotent.
  defp remove_workspace(workspace) do
    settings = Application.get_env(:veritas_core, :surreal, [])
    url = settings[:url]

    if is_binary(url) do
      remove_workspace_now(workspace, settings, url)
    else
      Mix.shell().info("no store url configured; leaving #{workspace} in place")
    end
  end

  defp remove_workspace_now(workspace, settings, url) do
    uri = URI.parse(url)

    endpoint =
      "#{uri.scheme || "http"}://#{uri.host}:#{uri.port || 80}#{if uri.path in [nil, ""], do: "/sql", else: uri.path}"

    headers = [
      {"accept", "application/json"},
      {"content-type", "text/plain"},
      {"authorization",
       "Basic " <> Base.encode64("#{settings[:user] || "root"}:#{settings[:pass] || "root"}")}
    ]

    for statement <- [
          "REMOVE DATABASE #{workspace}/#{workspace};",
          "REMOVE NAMESPACE #{workspace};"
        ] do
      request = %{url: endpoint, method: "post", headers: headers, body: statement}

      case :httpc.request(:post, request, [], body_format: :binary) do
        {:ok, _status, _headers, _response} ->
          :ok

        {:error, reason} ->
          Mix.shell().error("could not remove #{workspace}: #{inspect(reason)}")
      end
    end

    Mix.shell().info("removed the scratch Workspace #{workspace}")
  end
end
