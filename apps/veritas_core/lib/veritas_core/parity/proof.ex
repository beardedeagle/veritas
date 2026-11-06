defmodule Veritas.Core.Parity.Proof do
  @moduledoc """
  Executes independently mapped ExUnit assertions in fresh test VMs.

  Inventory declarations and evidence paths cannot certify themselves. Each
  receipt must identify exactly one successful test, its source and a completed
  suite in this invocation. Zero tests, skipped, excluded, failed or ambiguous
  events remain unproved. Candidate registries are evaluated in a fresh worker,
  never in the caller VM, after acquiring the invocation's lifetime channel.

  `Veritas.Core.Parity.Executor` owns worker cancellation and waits for worker
  shutdown. The existing datastore guardian owns its native store's teardown.
  """

  alias Veritas.Core.Parity.Contract

  @registry "apps/veritas_core/test/support/parity_proof_registry.ex"
  @formatter "apps/veritas_core/test/support/parity_checker_case.ex"
  @prefix "VERITAS_PARITY_EVENT "

  @doc """
  Runs registered proof cases and reports observed coverage and remaining gaps.

  Options are a positive `:timeout_ms` (default 120 seconds) and `:executable`
  (default the installed Elixir command). A missing executable refuses before
  any candidate registry or test source is evaluated.
  """
  @spec run(Path.t(), map(), keyword()) :: map()
  def run(root, manifest, opts \\ []) do
    required = Contract.obligations(manifest)

    executable = Keyword.get(opts, :executable, System.find_executable("elixir"))

    with :ok <- validate_timeout(opts),
         true <- Veritas.Core.Parity.Executor.available?(executable),
         {:ok, cases} <- registry(root, executable, opts),
         :ok <- validate_cases(root, cases, required),
         :ok <- validate_references(manifest, cases) do
      executed = Enum.map(cases, &execute(root, &1, executable, opts))
      proved = for %{passed: true, cell: key} <- executed, do: key

      failures =
        for %{passed: false, id: id} <- executed,
            do: "P2: #{id} did not execute exactly one passing proof with confirmed cleanup"

      %{
        proved: proved,
        executed: executed,
        failures: failures ++ missing_proofs(required, proved)
      }
    else
      false ->
        %{
          proved: [],
          executed: [],
          failures: [
            "P0: proof containment unavailable; no candidate code evaluated"
            | missing_proofs(required, [])
          ]
        }

      {:error, message} ->
        %{proved: [], executed: [], failures: ["P0: " <> message]}
    end
  end

  defp validate_timeout(opts) do
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    if is_integer(timeout) and timeout > 0,
      do: :ok,
      else: {:error, "timeout_ms must be a positive integer"}
  end

  defp registry(root, executable, opts) do
    with {:ok, path} <- owned_file(root, @registry),
         {:ok, _formatter} <- owned_file(root, @formatter) do
      code = ~S"""
      path = hd(System.argv())
      modules = Code.compile_file(path)
      expected = Veritas.Core.Test.ParityProofRegistry
      unless Enum.any?(modules, fn {mod, _} -> mod == expected end) and function_exported?(expected, :cases, 0),
        do: raise("independent proof registry must implement cases/0 in its own source")
      IO.puts("VERITAS_PARITY_REGISTRY " <> Jason.encode!(expected.cases()))
      """

      {output, status, clean?} =
        Veritas.Core.Parity.Executor.run(
          executable,
          [
            "--erl",
            "+S 2:2",
            "-pa",
            Path.dirname(to_string(:code.which(Jason))),
            "-e",
            code,
            path
          ],
          root,
          Keyword.get(opts, :timeout_ms, 120_000)
        )

      lines =
        output
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "VERITAS_PARITY_REGISTRY "))

      with true <- status == 0 and clean?,
           [line] <- lines,
           {:ok, entries} when is_list(entries) <-
             Jason.decode(String.replace_prefix(line, "VERITAS_PARITY_REGISTRY ", "")) do
        {:ok, Enum.map(entries, &decode_entry/1)}
      else
        _ -> {:error, "independent proof registry did not finish safely: " <> output}
      end
    end
  rescue
    error ->
      {:error, "independent proof registry could not be loaded: #{Exception.message(error)}"}
  end

  defp decode_entry(entry) when is_map(entry) do
    fields = [:id, :operation, :surface, :aspect_kind, :aspect, :file, :test]
    result = Map.new(fields, &{&1, entry[Atom.to_string(&1)]})

    mode =
      case entry["mode"] do
        nil -> :mix
        "mix" -> :mix
        "elixir" -> :elixir
        _ -> :invalid
      end

    Map.put(result, :mode, mode)
  end

  defp decode_entry(entry), do: entry

  defp execute(root, entry, executable, opts) do
    {directory, args} = command(root, entry)

    {output, status, clean?} =
      Veritas.Core.Parity.Executor.run(
        executable,
        args,
        directory,
        Keyword.get(opts, :timeout_ms, 120_000)
      )

    receipt = validate_receipt(root, entry, output, status)
    %{receipt | passed: receipt.passed and clean?}
  end

  defp command(root, %{mode: :elixir} = entry) do
    code = ~S"""
    [formatter, file, id] = System.argv()
    Code.require_file(formatter)
    ExUnit.start(autorun: false, formatters: [Veritas.Core.Test.ParityCheckerCase],
      exclude: [:test], include: [parity_proof: id])
    Code.require_file(file)
    result = ExUnit.run()
    System.halt(if result.failures == 0, do: 0, else: 1)
    """

    {root,
     [
       "--erl",
       "+S 2:2",
       "-pa",
       Path.dirname(to_string(:code.which(Jason))),
       "-e",
       code,
       Path.join(root, @formatter),
       Path.join(root, entry.file),
       entry.id
     ]}
  end

  defp command(root, entry) do
    file = Path.join(root, entry.file)
    app_root = entry_app_root(root, file)

    {app_root,
     [
       "--erl",
       "+S 2:2",
       "-S",
       "mix",
       "test",
       Path.relative_to(file, app_root),
       "--only",
       "parity_proof:#{entry.id}",
       "--formatter",
       "Veritas.Core.Test.ParityCheckerCase"
     ]}
  end

  defp validate_cases(root, cases, required) when is_list(cases) and cases != [] do
    keys = Enum.map(required, &cell_key/1)
    errors = Enum.flat_map(cases, &case_errors(root, &1, keys))
    ids = Enum.map(cases, &case_value(&1, :id))
    identities = Enum.map(cases, &{case_value(&1, :file), case_value(&1, :test)})

    errors =
      errors ++
        duplicate_error(ids, "proof case IDs") ++
        duplicate_error(identities, "proof test identities")

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
  end

  defp validate_cases(_root, _cases, _required),
    do: {:error, "the independent proof registry needs nonempty case definitions"}

  defp case_errors(root, entry, keys) when is_map(entry) do
    fields = [:id, :operation, :surface, :file, :test]
    valid_text = Enum.all?(fields, &text?(Map.get(entry, &1)))
    valid_kind = is_nil(entry[:aspect_kind]) or text?(entry[:aspect_kind])
    valid_aspect = is_nil(entry[:aspect]) or text?(entry[:aspect])
    valid_mode = Map.get(entry, :mode, :mix) in [:elixir, :mix]

    if valid_text and valid_kind and valid_aspect and valid_mode do
      validate_case_target(root, entry, keys)
    else
      ["proof case needs id/operation/surface/file/test and a valid aspect and execution mode"]
    end
  end

  defp case_errors(_root, _entry, _keys), do: ["proof cases must be maps"]

  defp validate_case_target(root, entry, keys) do
    errors = if cell_key(entry) in keys, do: [], else: ["#{entry.id}: unknown proof cell"]

    errors =
      if String.starts_with?(entry.test, "test "),
        do: errors,
        else: ["#{entry.id}: invalid exact test name" | errors]

    case owned_file(root, entry.file) do
      {:ok, _path} -> errors
      {:error, message} -> [message | errors]
    end
  end

  defp validate_references(manifest, cases) do
    registry = Map.new(cases, &{&1.id, &1})

    errors =
      for operation <- manifest["operations"],
          {surface, binding} <- operation["bindings"],
          id <- Map.get(binding, "proof_ids", []),
          not matching_reference?(registry[id], operation["id"], surface),
          do: "#{operation["id"]}/#{surface}: fabricated or mismatched proof reference #{id}"

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
  end

  defp matching_reference?(%{operation: operation, surface: surface}, operation, surface),
    do: true

  defp matching_reference?(_entry, _operation, _surface), do: false

  @doc """
  Checks the identity and outcome of an execution trace without executing it.

  ## Arguments
    * `root` — the tree used to resolve the registered test file.
    * `entry` — an independently authored, validated proof-case definition.
    * `output` — the output to check against the ExUnit formatter protocol.
    * `status` — the observed subprocess exit status.

  ## Returns
    * A receipt with `passed: true` only for one exact successful test and suite.
      This function only validates a protocol trace. `run/3` additionally requires
      execution and confirmed worker shutdown in the current invocation.
  """
  @spec validate_receipt(Path.t(), map(), String.t(), integer()) :: map()
  def validate_receipt(root, entry, output, status) do
    events = parse_events(output)
    finished = for %{"event" => "test_finished"} = event <- events, do: event
    selected = Enum.reject(finished, &(&1["state"] == "excluded"))
    suites = Enum.filter(events, &(&1["event"] == "suite_finished"))

    observed_count_matches =
      case suites do
        [%{"tests" => count}] when is_integer(count) -> count == length(finished)
        _ -> false
      end

    matching_ids = Enum.count(finished, &(&1["id"] == entry.id))
    valid_events = Enum.all?(events, &(&1["event"] in ["test_finished", "suite_finished"]))

    passed =
      status == 0 and observed_count_matches and matching_ids == 1 and valid_events and
        successful_test?(selected, root, entry)

    %{id: entry.id, cell: cell_key(entry), passed: passed, exit_status: status, output: output}
  rescue
    error ->
      %{
        id: entry.id,
        cell: cell_key(entry),
        passed: false,
        exit_status: nil,
        output: Exception.message(error)
      }
  end

  defp parse_events(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, @prefix))
    |> Enum.map(&Jason.decode(String.replace_prefix(&1, @prefix, "")))
    |> Enum.map(fn
      {:ok, event} when is_map(event) -> event
      _invalid -> %{"event" => "invalid"}
    end)
  end

  defp successful_test?([event], root, entry) do
    event["id"] == entry.id and event["test"] == entry.test and
      event["state"] == "passed" and text?(event["module"]) and
      matching_file?(event["file"], root, entry.file)
  end

  defp successful_test?(_events, _root, _entry), do: false

  defp matching_file?(file, root, expected) when is_binary(file) do
    expected = Path.expand(expected, root)
    app_root = entry_app_root(root, expected)
    Path.expand(file, root) == expected or Path.expand(file, app_root) == expected
  end

  defp matching_file?(_file, _root, _expected), do: false

  defp entry_app_root(root, expected) do
    case Path.split(Path.relative_to(expected, root)) do
      ["apps", app | _rest] -> Path.join([root, "apps", app])
      _other -> root
    end
  end

  defp missing_proofs(required, proved) do
    for cell <- required,
        cell_key(cell) not in proved or cell.status in ~w(missing open not-examined),
        do: "P1: #{label(cell)} remains unproved (#{cell.status})"
  end

  defp owned_file(root, file) when is_binary(file) do
    root = Path.expand(root)
    path = Path.expand(file, root)

    if Path.type(file) == :relative and String.starts_with?(path, root <> "/") and
         not symlink_path?(path, root) and File.regular?(path) do
      {:ok, path}
    else
      {:error, "independent proof file is missing or outside the candidate tree: #{file}"}
    end
  end

  defp owned_file(_root, _file), do: {:error, "independent proof file must be a relative path"}

  defp symlink_path?(root, root), do: false

  defp symlink_path?(path, root) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _other -> symlink_path?(Path.dirname(path), root)
    end
  end

  defp duplicate_error(values, label) do
    if Enum.uniq(values) == values, do: [], else: ["duplicate #{label}"]
  end

  defp case_value(entry, key) when is_map(entry), do: entry[key]
  defp case_value(_entry, _key), do: nil
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp cell_key(cell), do: {cell.operation, cell.surface, cell[:aspect_kind], cell[:aspect]}
  defp label(cell), do: Enum.join(Enum.reject(Tuple.to_list(cell_key(cell)), &is_nil/1), "/")
end
