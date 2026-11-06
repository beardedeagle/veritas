defmodule Mix.Tasks.Veritas.Parity.Check do
  @shortdoc "Validates parity inventory and executes independently mapped proof cases"

  @moduledoc """
  Validates the MVP operation inventory against a fixed contract baseline.

      mix veritas.parity.check
      mix veritas.parity.check --proof
      mix veritas.parity.check --root /path/to/candidate

  **Inventory mode is declarative, never behavioral proof.** A declared
  `behaviorally-verified` state is only a claim in operations.json. Inventory
  mode refuses malformed declarations and missing capabilities, but accepts
  implemented-unverified declarations and prints unresolved requirements.

  `--proof` evaluates the independently authored case mapping in a fresh VM,
  then executes its exact ExUnit tests in their application test environment.
  Worker lifecycle channels are armed before candidate code runs; timeout and
  caller cancellation stop owned BEAM workers, and the supervisor confirms
  shutdown before a receipt can count. The existing store guardian owns native
  datastore teardown. This trusted-test protocol is not an arbitrary native
  process sandbox.

  A proof needs matching successful ExUnit events from the current invocation.
  Missing cases, zero tests, skipped/excluded/failed tests and unresolved
  requirements stay red. Manifest evidence strings and claimed proof IDs never
  certify themselves; tests own the independent behavioral assertions.

  The fixed operation IDs, surfaces, ticket types, query modes, CSV/JSONL
  formats and shared-filter obligation come from docs/04:479-481. CI does not
  need docs/: the baseline is pinned in the implementation as well as carried
  in the manifest. Neither enumeration may shrink it. Both parent bindings
  and required aspects contribute conservatively to coverage counts.

  Compile changed task/helper sources explicitly before invoking a Mix task.
  A task does not compile itself. Source-loaded instrument tests may compile
  just this file and its helpers, without starting Veritas or the datastore.
  Real proof cases use their app's test environment and must be serialized
  with other users of shared build artifacts and test services.
  """

  use Mix.Task

  alias Veritas.Core.Parity.{Contract, Proof}

  @manifest "apps/veritas_core/priv/parity/operations.json"

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv, strict: [quiet: :boolean, root: :string, proof: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("parity check accepts only --root PATH, --quiet and --proof")
    end

    root = Path.expand(opts[:root] || project_root())
    manifest = read_manifest!(Path.join(root, @manifest))
    validate!(manifest)
    counts = Contract.counts(manifest)
    inventory_failures = inventory_failures(manifest)

    unless opts[:quiet], do: print_inventory(manifest, counts)

    proof = if opts[:proof], do: Proof.run(root, manifest)
    if proof, do: print_proof(proof, opts[:quiet])

    failures = inventory_failures ++ if(proof, do: proof.failures, else: [])
    refuse_failures(failures, counts, opts[:proof])
  end

  @doc """
  Finds the candidate repository by walking upwards from the current directory.

  ## Returns
    * The absolute directory containing the operation manifest.

  ## Raises
    * `Mix.Error` when no candidate manifest is present.
  """
  @spec project_root() :: Path.t()
  def project_root do
    find_root(Path.expand(".")) || Mix.raise("no #{@manifest} found above the current directory")
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join(dir, @manifest)) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_root(Path.dirname(dir))
    end
  end

  defp read_manifest!(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- Jason.decode(contents) do
      manifest
    else
      {:error, %Jason.DecodeError{}} ->
        Mix.raise("invalid parity manifest: malformed JSON")

      {:error, reason} ->
        Mix.raise("the parity manifest could not be read: #{:file.format_error(reason)}")
    end
  end

  defp validate!(manifest) do
    case Contract.validate(manifest) do
      :ok -> :ok
      {:error, errors} -> Mix.raise("invalid parity manifest:\n" <> Enum.join(errors, "\n"))
    end
  end

  defp inventory_failures(manifest) do
    parent_failures =
      for operation <- manifest["operations"],
          {surface, binding} <- operation["bindings"],
          binding["status"] == "missing",
          do: "F1: #{operation["id"]}/#{surface} has no binding"

    aspect_failures =
      for cell <- Contract.obligations(manifest),
          not is_nil(cell.aspect),
          cell.status == "missing",
          do: "F2: #{label(cell)} is missing"

    parent_failures ++ aspect_failures
  end

  defp print_inventory(manifest, counts) do
    Mix.shell().info("DECLARATIVE operation inventory — not behavioral proof")
    Mix.shell().info("  #{@manifest}")
    Mix.shell().info("  #{counts.operations} contract operation(s)")
    Mix.shell().info("  #{counts.required} required binding(s)")
    Mix.shell().info("declared coverage (conservative parent + required-aspect rollup)")

    for {state, count} <- Enum.sort(counts.states) do
      Mix.shell().info("  #{state} — #{count}")
    end

    Mix.shell().info("required proof obligations — #{length(Contract.obligations(manifest))}")

    for cell <- Contract.obligations(manifest) do
      Mix.shell().info("  #{label(cell)} — #{cell.status} (declared)")
    end
  end

  defp print_proof(proof, quiet?) do
    unless quiet? do
      Mix.shell().info("EXECUTED proof — #{length(proof.executed)} independently mapped case(s)")

      for receipt <- proof.executed do
        status = if receipt.passed, do: "PASS", else: "FAIL"
        Mix.shell().info("  #{status} #{receipt.id} (exit #{inspect(receipt.exit_status)})")
        Mix.shell().info(receipt.output)
      end

      Mix.shell().info("  #{length(Enum.uniq(proof.proved))} cell(s) proved in this invocation")
    end
  end

  defp refuse_failures([], _counts, _strict?), do: :ok

  defp refuse_failures(failures, counts, strict?) do
    Enum.each(failures, fn failure -> Mix.shell().error(failure) end)
    mode = if strict?, do: "strict proof", else: "declarative inventory"
    unverified = counts.required - Map.get(counts.states, "behaviorally-verified", 0)

    Mix.raise(
      "#{mode} refused: #{length(failures)} failure(s); " <>
        "#{unverified} binding(s) not declared behaviorally-verified. " <>
        "Inventory declarations do not establish executed proof or complete product coverage."
    )
  end

  defp label(cell),
    do:
      Enum.join(
        Enum.reject([cell.operation, cell.surface, cell.aspect_kind, cell.aspect], &is_nil/1),
        "/"
      )
end
