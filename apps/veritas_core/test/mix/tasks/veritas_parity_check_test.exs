defmodule Veritas.Core.ParityCheckTest do
  @moduledoc """
  Independent regressions for the parity instrument, not product coverage.

  The cases below are transcribed from docs/04:479-481, not operations.json.
  An inventory-only positive control is deliberately unverified. Strict proof
  must not promote it, plausible source references, or nonexistent tests.
  Fixture trees are retained under _build/instrument-correction-20261104/sdet.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Veritas.Parity.Check

  @surfaces ~w(cli graphql ui)
  @types ~w(incident change service_request problem vulnerability)
  @ticket_ids ~w(ticket.create ticket.update ticket.transition ticket.comment ticket.assign)
  @other_ids ~w(ci.create ci.update ci.retire relationship.create relationship.delete ci.query search.global bulk.transition bulk.assign audit.query audit.export dashboard.report agent_run.start agent_run.status agent_run.approve agent_run.reject agent_run.transcript discovery.trigger adapter.list ci.observation_fetch)
  @repo Path.expand("../../../../..", __DIR__)

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Process.register(self(), :mix_shell)

    on_exit(fn ->
      Mix.shell(previous_shell)

      # Candidate registries are compiled dynamically. Do not leak a fixture's
      # module into another test. Same-VM stale-registry controls intentionally
      # keep it loaded between their two invocations within a single test.
      for module <- [Veritas.Core.Test.ParityProofRegistry, Veritas.WrongProofRegistry] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    :ok
  end

  @tag parallel_compile: true
  test "normal parallel compilation builds the task and proof helpers in a fresh VM" do
    root = fixture_root()
    output_dir = Path.join(root, "parallel-ebin")
    File.mkdir_p!(output_dir)

    # Preserve the actual relative layout so any task-side helper loader runs
    # exactly as it would during Mix compilation. Never reuse loaded helpers.
    relative_sources = [
      "apps/veritas_core/lib/veritas_core/parity/contract.ex",
      "apps/veritas_core/lib/veritas_core/parity/executor.ex",
      "apps/veritas_core/lib/veritas_core/parity/proof.ex",
      "apps/veritas_core/lib/mix/tasks/veritas.parity.check.ex"
    ]

    sources =
      Enum.map(relative_sources, fn relative ->
        destination = Path.join(root, relative)
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(Path.join(@repo, relative), destination)
        assert File.read!(destination) == File.read!(Path.join(@repo, relative))
        destination
      end)

    worker = Path.join(root, "parallel_compile.exs")

    File.write!(worker, ~S"""
    Mix.start()
    # This trusted compiler worker starts no descendants. EOF shuts down this
    # VM if its owning test process disappears while compilation is running.
    Task.start(fn -> IO.read(:stdio, :eof); System.halt(2) end)
    [output_dir | sources] = System.argv()
    expected = [Veritas.Core.Parity.Contract, Veritas.Core.Parity.Executor, Veritas.Core.Parity.Proof, Mix.Tasks.Veritas.Parity.Check]
    Enum.each(expected, fn module ->
      unless :code.is_loaded(module) == false and :code.which(module) == :non_existing do
        IO.puts("NOT_FRESH_MODULE=#{inspect(module)}")
        System.halt(2)
      end
    end)
    IO.puts("FRESH_MODULES=4")
    result = Kernel.ParallelCompiler.compile_to_path(sources, output_dir,
      return_diagnostics: true,
      each_module: fn _file, module, _binary ->
        IO.puts("PARALLEL_COMPILED=#{inspect(module)}")
      end)
    IO.inspect(result, label: "PARALLEL_COMPILER_RESULT", limit: :infinity)
    passed = case result do
      {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} ->
        Enum.sort(modules) == Enum.sort(expected)
      _ -> false
    end
    System.halt(if passed, do: 0, else: 1)
    """)

    {output, exit_code} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 4:4",
          "-pa",
          Path.dirname(to_string(:code.which(Jason))),
          worker,
          output_dir | sources
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(root, "parallel-compiler.log"), output)
    assert output =~ "FRESH_MODULES=4", output
    assert exit_code == 0, "fresh parallel compilation failed in #{root}:\n#{output}"

    for module <- [
          Veritas.Core.Parity.Contract,
          Veritas.Core.Parity.Proof,
          Mix.Tasks.Veritas.Parity.Check
        ] do
      assert File.regular?(Path.join(output_dir, Atom.to_string(module) <> ".beam"))
    end
  end

  test "a complete unverified inventory is accepted only as inventory, with 45 operations and 135 cells" do
    {result, output} = check(manifest())
    assert result == :ok, output
    assert output =~ "45 contract operation(s)"
    assert output =~ "135 required binding(s)"
    assert output =~ "implemented-unverified"
    refute output =~ ~r/behaviorally-verified\s*—\s*[1-9]/
  end

  for {label, json} <- [
        {"empty object", "{}"},
        {"empty input", ""},
        {"invalid JSON", "{\"operations\":"},
        {"array JSON", "[]"},
        {"null JSON", "null"},
        {"scalar JSON", "17"}
      ] do
    test "#{label} is a diagnostic refusal, not success or a checker crash" do
      assert_refused(unquote(json))
    end
  end

  test "deleting both contract enumeration and operations cannot erase the contract" do
    input = manifest() |> put_in(["meta", "enumeration"], %{}) |> Map.put("operations", [])
    assert_refused(input)
  end

  test "deleting one operation and its enumeration row cannot shrink the required set" do
    input = manifest() |> remove_operation("ticket.comment")
    assert_refused(input)
  end

  test "duplicate IDs are refused" do
    input = manifest()
    assert_refused(Map.update!(input, "operations", &[hd(&1) | &1]))
  end

  test "an unknown ID cannot be legitimized by adding it to both declarations" do
    extra = operation("invented.operation")

    input =
      manifest()
      |> update_in(["meta", "enumeration"], &Map.put(&1, "invented.operation", @surfaces))
      |> Map.update!("operations", &(&1 ++ [extra]))

    assert_refused(input)
  end

  test "deleting the operation collection is refused" do
    assert_refused(Map.delete(manifest(), "operations"))
  end

  test "deleting the enumeration is refused" do
    assert_refused(update_in(manifest(), ["meta"], &Map.delete(&1, "enumeration")))
  end

  test "an enumeration-only ID is refused" do
    assert_refused(
      update_in(manifest(), ["meta", "enumeration"], &Map.put(&1, "ghost", @surfaces))
    )
  end

  test "a missing enumeration ID is refused" do
    assert_refused(update_in(manifest(), ["meta", "enumeration"], &Map.delete(&1, "ci.create")))
  end

  test "status vocabulary cannot be extended by the input under examination" do
    input =
      manifest()
      |> update_in(["meta", "coverage_states"], &Map.put(&1, "invented-status", "self-approved"))
      |> change_operation(
        "ci.create",
        &put_in(&1, ["bindings", "cli", "status"], "invented-status")
      )

    assert_refused(input)
  end

  test "surface vocabulary cannot be replaced in both declarations" do
    input = manifest()

    enumeration =
      Map.new(input["meta"]["enumeration"], fn {id, _} -> {id, ~w(cli graphql telepathy)} end)

    input =
      input
      |> put_in(["meta", "enumeration"], enumeration)
      |> Map.update!("operations", fn operations ->
        Enum.map(operations, fn operation ->
          operation
          |> Map.put("surfaces", ~w(cli graphql telepathy))
          |> update_in(["bindings"], fn bindings ->
            {ui, rest} = Map.pop!(bindings, "ui")
            Map.put(rest, "telepathy", Map.put(ui, "kind", "telepathy"))
          end)
        end)
      end)

    assert_refused(input)
  end

  for kind <- [nil, "", "invented-kind"] do
    test "aspect kind #{inspect(kind)} is refused" do
      input =
        change_operation(manifest(), "ci.query", &put_in(&1, ["aspects", "kind"], unquote(kind)))

      assert_refused(input)
    end
  end

  test "an empty non-ticket aspect set is refused" do
    assert_refused(
      change_operation(manifest(), "ci.query", &put_in(&1, ["aspects", "states"], %{}))
    )
  end

  test "an unknown query aspect cannot replace a required mode" do
    input =
      change_operation(manifest(), "ci.query", fn operation ->
        update_in(operation, ["aspects", "states"], fn states ->
          {state, rest} = Map.pop!(states, "by_type")
          Map.put(rest, "invented-mode", state)
        end)
      end)

    assert_refused(input)
  end

  test "an empty aspect name is refused" do
    input =
      change_operation(manifest(), "ci.query", fn operation ->
        update_in(operation, ["aspects", "states"], fn states ->
          {state, rest} = Map.pop!(states, "by_type")
          Map.put(rest, "", state)
        end)
      end)

    assert_refused(input)
  end

  test "a ticket type cannot be renamed in both declarations" do
    input =
      change_operation(manifest(), "ticket.create", fn operation ->
        operation
        |> Map.put("ticket_types", ~w(alien change service_request problem vulnerability))
        |> update_in(["aspects", "states"], fn states ->
          {state, rest} = Map.pop!(states, "incident")
          Map.put(rest, "alien", state)
        end)
      end)

    assert_refused(input)
  end

  for status <- [nil, "", "invented-status"] do
    test "aspect status #{inspect(status)} is refused" do
      input =
        change_operation(manifest(), "ticket.create", fn operation ->
          put_in(operation, ["aspects", "states", "incident", "cli"], unquote(status))
        end)

      assert_refused(input)
    end
  end

  test "an omitted aspect surface is refused rather than silently not examined" do
    input =
      change_operation(manifest(), "ticket.create", fn operation ->
        update_in(operation, ["aspects", "states", "incident"], &Map.delete(&1, "ui"))
      end)

    assert_refused(input)
  end

  test "a missing parent cannot be certified by a verified aspect" do
    input =
      change_operation(manifest(), "ticket.create", fn operation ->
        operation
        |> put_in(["bindings", "cli", "status"], "missing")
        |> put_in(["bindings", "cli", "identifier"], nil)
        |> put_in(["aspects", "states", "incident", "cli"], "behaviorally-verified")
      end)

    assert_refused(input)
  end

  test "a verified parent cannot conceal unverified required aspects" do
    input =
      change_operation(manifest(), "ticket.create", fn operation ->
        put_in(operation, ["bindings", "cli", "status"], "behaviorally-verified")
      end)

    assert_refused(input)
  end

  test "missing CI query modes downgrade the non-ticket binding totals" do
    input =
      change_operation(manifest(), "ci.query", fn operation ->
        operation
        |> put_in(["aspects", "states", "by_type"], states("behaviorally-verified"))
        |> put_in(["aspects", "states", "by_relationship"], states("missing"))
      end)

    {result, output} = check(input)
    assert match?({:refused, _}, result), output
    refute output =~ ~r/behaviorally-verified\s*—\s*[1-9]/, output
    assert output =~ ~r/missing\s*—\s*3\b/, output
  end

  test "CSV and JSONL remain required obligations even though export is one operation" do
    assert_refused(change_operation(manifest(), "audit.export", &Map.put(&1, "formats", [])))
  end

  test "CSV and JSONL require per-surface aspect states, not format names alone" do
    input = change_operation(manifest(), "audit.export", &Map.delete(&1, "aspects"))
    assert_refused(input)
  end

  test "shared filter obligations require states for all three surfaces" do
    input = update_in(manifest(), ["meta", "filter_grammar", "states"], &Map.delete(&1, "ui"))
    assert_refused(input)
  end

  test "the shared filter requirement cannot disappear with its metadata" do
    assert_refused(update_in(manifest(), ["meta"], &Map.delete(&1, "filter_grammar")))
  end

  test "strict proof refuses an all-unverified inventory without executable tests" do
    assert_refused(manifest(), ["--proof"])
  end

  test "strict proof refuses nonexistent identifiers, locations and test evidence" do
    input = certify(manifest(), "does.not.exist", "missing/source.ex:1", ["missing/test.exs:1"])
    assert_refused(input, ["--proof"])
  end

  test "strict proof refuses plausible source names and an unrelated real test citation" do
    input =
      certify(
        manifest(),
        "CI.list/2",
        "apps/veritas_core/lib/veritas_core/ci.ex:58",
        ["apps/veritas_web/test/veritas_web/ci_surfaces_test.exs:63"]
      )

    assert_refused(input, ["--proof"])
  end

  for {label, tag, assertion, expected_state, expected_exit} <- [
        {"passing", "@tag parity_proof: \"runner.control\"", "assert 2 + 2 == 4", "passed", 0},
        {"failing", "@tag parity_proof: \"runner.control\"",
         "flunk(\"negative execution control\")", "failed", 1},
        {"skipped", "@tag parity_proof: \"runner.control\"\n@tag skip: true",
         "flunk(\"must not execute\")", "skipped", 0},
        {"excluded", "@tag parity_proof: \"unselected.control\"", "flunk(\"must not execute\")",
         "excluded", 0}
      ] do
    test "the formatter reports an actual #{label} assertion without inventing a pass" do
      {events, exit_code} = formatter_control(unquote(tag), unquote(assertion))
      assert exit_code == unquote(expected_exit)

      assert [
               %{
                 "event" => "test_finished",
                 "test" => "test runner control",
                 "state" => unquote(expected_state)
               }
             ] =
               Enum.filter(events, &(&1["event"] == "test_finished"))

      assert %{"event" => "suite_finished", "tests" => 1} = List.last(events)
    end
  end

  test "a zero-test runner emits suite completion but no passing test event" do
    {events, 0} = formatter_control(nil, nil)
    assert events == [%{"event" => "suite_finished", "tests" => 0}]
  end

  @tag proof_guard: true
  test "unqualified containment refuses before loading or executing the candidate test source" do
    {root, entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
    marker = Path.join(root, "candidate-source-was-executed")
    source = Path.join(root, entry.file)
    File.write!(source, "File.write!(#{inspect(marker)}, \"executed\")\n" <> File.read!(source))

    report = execute_proof(root, manifest(), executable: nil)
    assert report.executed == []
    assert report.proved == []

    assert Enum.any?(
             report.failures,
             &(String.starts_with?(&1, "P0:") and String.contains?(&1, "containment"))
           )

    assert Enum.any?(report.failures, &String.starts_with?(&1, "P1:"))
    refute File.exists?(marker), "a fail-closed runner must not evaluate candidate test source"
  end

  @tag proof_guard: true
  test "unqualified containment refuses before candidate registry top-level code is evaluated" do
    {root, _entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
    marker = Path.join(root, "registry-top-level.marker")
    registry = Path.join(root, "apps/veritas_core/test/support/parity_proof_registry.ex")

    File.write!(
      registry,
      "File.write!(#{inspect(marker)}, \"registry top-level evaluated\")\n" <>
        File.read!(registry)
    )

    report = execute_proof(root, manifest(), executable: nil)
    assert report.executed == []
    assert report.proved == []

    assert Enum.any?(
             report.failures,
             &(String.starts_with?(&1, "P0:") and String.contains?(&1, "containment"))
           )

    assert Enum.any?(report.failures, &String.starts_with?(&1, "P1:"))
    refute File.exists?(marker), "candidate registry top-level executed before refusal: #{marker}"
  end

  @tag proof_guard: true
  test "unqualified containment refuses before candidate registry cases/0 is called" do
    {root, entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
    marker = Path.join(root, "registry-cases-call.marker")
    registry = Path.join(root, "apps/veritas_core/test/support/parity_proof_registry.ex")

    File.write!(registry, """
    defmodule Veritas.Core.Test.ParityProofRegistry do
      def cases do
        File.write!(#{inspect(marker)}, "registry cases/0 evaluated")
        #{inspect([entry], limit: :infinity)}
      end
    end
    """)

    report = execute_proof(root, manifest(), executable: nil)
    assert report.executed == []
    assert report.proved == []

    assert Enum.any?(
             report.failures,
             &(String.starts_with?(&1, "P0:") and String.contains?(&1, "containment"))
           )

    assert Enum.any?(report.failures, &String.starts_with?(&1, "P1:"))
    refute File.exists?(marker), "candidate registry cases/0 executed before refusal: #{marker}"
  end

  test "the proof executor runs a positive control but does not certify the remaining contract" do
    {root, _entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert 2 + 2 == 4")
    report = execute_proof(root)
    assert [%{id: "runner.control", passed: true, exit_status: 0}] = report.executed
    assert report.proved == [{"ci.query", "cli", "query_mode", "by_type"}]
    assert report.failures != []
    assert Enum.all?(report.failures, &String.starts_with?(&1, "P1:"))
  end

  for {label, tag, assertion} <- [
        {"failed", "@tag parity_proof: \"runner.control\"", "flunk(\"negative control\")"},
        {"skipped", "@tag parity_proof: \"runner.control\"\n@tag skip: true",
         "flunk(\"must not run\")"},
        {"excluded", "@tag parity_proof: \"another.control\"", "flunk(\"must not run\")"},
        {"zero-test", nil, nil}
      ] do
    test "the proof executor refuses a #{label} run instead of promoting exit zero" do
      {root, _entry} = proof_fixture(unquote(tag), unquote(assertion))
      report = execute_proof(root)
      assert [%{passed: false}] = report.executed
      assert report.proved == []
      assert Enum.any?(report.failures, &String.starts_with?(&1, "P2:"))
    end
  end

  test "a matching tag cannot certify the wrong exact test name" do
    {root, entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
    write_registry(root, [%{entry | test: "test a different assertion"}])
    report = execute_proof(root)
    assert [%{passed: false}] = report.executed
    assert report.proved == []
  end

  test "an old receipt file without a current executable test cannot prove a cell" do
    {root, entry} = proof_fixture(nil, nil)

    File.write!(
      Path.join(root, "previous-proof-receipt.json"),
      Jason.encode!(%{id: entry.id, state: "passed"})
    )

    report = execute_proof(root)
    assert [%{passed: false}] = report.executed
    assert report.proved == []
  end

  @tag proof_stdout_guard: true
  test "stdout cannot invent a passing ExUnit test in a zero-test suite" do
    {root, entry} = proof_fixture(nil, nil)
    path = Path.join(root, entry.file)

    invented = %{
      "event" => "test_finished",
      "id" => entry.id,
      "module" => "Veritas.ParityRunnerControl",
      "test" => entry.test,
      "file" => path,
      "state" => "passed"
    }

    File.write!(
      path,
      "IO.puts(" <>
        inspect("VERITAS_PARITY_EVENT " <> Jason.encode!(invented)) <>
        ")\n" <>
        File.read!(path)
    )

    report = execute_proof(root)
    assert [%{passed: false}] = report.executed
    assert report.proved == []
  end

  for {label, replacement} <- [
        {"empty", ""},
        {"wrong-module", "defmodule Veritas.WrongProofRegistry do\n def cases, do: []\nend\n"}
      ] do
    test "an #{label} registry cannot reuse cases from an earlier candidate in the same VM" do
      {first, _entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
      assert [%{passed: true}] = execute_proof(first).executed
      {second, _entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")

      File.write!(
        Path.join(second, "apps/veritas_core/test/support/parity_proof_registry.ex"),
        unquote(replacement)
      )

      report = execute_proof(second)
      assert report.executed == []
      assert report.proved == []
      assert Enum.any?(report.failures, &String.starts_with?(&1, "P0:"))
    end
  end

  test "a duplicate completion with the same proof ID remains ambiguous even when excluded" do
    {root, entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
    path = Path.join(root, entry.file)

    duplicate = %{
      "event" => "test_finished",
      "id" => entry.id,
      "module" => "Veritas.ParityRunnerControl",
      "test" => entry.test,
      "file" => path,
      "state" => "excluded"
    }

    File.write!(
      path,
      "IO.puts(" <>
        inspect("VERITAS_PARITY_EVENT " <> Jason.encode!(duplicate)) <> ")\n" <> File.read!(path)
    )

    report = execute_proof(root)
    assert [%{passed: false}] = report.executed
    assert report.proved == []
  end

  test "a nonexistent proof reference cannot hide behind a valid executable registry" do
    {root, _entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")

    input =
      change_operation(
        manifest(),
        "ci.query",
        &put_in(&1, ["bindings", "cli", "proof_ids"], ["invented.proof"])
      )

    report = execute_proof(root, input)
    assert report.executed == []
    assert report.proved == []
    assert Enum.any?(report.failures, &String.contains?(&1, "invented.proof"))
  end

  test "a real proof identifier cannot be borrowed by a different surface" do
    {root, _entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")

    input =
      change_operation(
        manifest(),
        "ci.query",
        &put_in(&1, ["bindings", "ui", "proof_ids"], ["runner.control"])
      )

    report = execute_proof(root, input)
    assert report.executed == []
    assert report.proved == []
  end

  @tag proof_timeout: true
  test "a hung proof is bounded and its explicitly started child process is gone" do
    {root, entry} = proof_fixture("@tag parity_proof: \"runner.control\"", "assert true")
    portfile = Path.join(root, "owned-child.port")
    readyfile = Path.join(root, "owned-child-confirmed-ready")
    child_source = Path.join(root, "owned_child.exs")
    path = Path.join(root, entry.file)

    # Only the Elixir executable already required by proof mode is used.
    # The private loopback shutdown channel also cleans up a failing control,
    # without a process scan, PID guessing, or an extra kill/sleep executable.
    File.write!(child_source, """
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    File.write!(#{inspect(portfile)}, Integer.to_string(port))
    serve = fn serve ->
      {:ok, socket} = :gen_tcp.accept(listener)
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, "stop"} -> System.halt(0)
        {:ok, "ping"} -> :gen_tcp.send(socket, "pong"); :gen_tcp.close(socket); serve.(serve)
        _ -> :gen_tcp.close(socket); serve.(serve)
      end
    end
    serve.(serve)
    """)

    on_exit(fn ->
      if File.exists?(portfile) do
        case :gen_tcp.connect(
               {127, 0, 0, 1},
               String.to_integer(File.read!(portfile)),
               [:binary, active: false],
               500
             ) do
          {:ok, socket} ->
            :gen_tcp.send(socket, "stop")
            :gen_tcp.close(socket)

          {:error, _reason} ->
            :ok
        end
      end
    end)

    File.write!(path, """
    defmodule Veritas.ParityRunnerControl do
      use ExUnit.Case
      @tag parity_proof: "runner.control"
      test "runner control" do
        child = Port.open({:spawn_executable, System.find_executable("elixir")}, [:binary, args: [#{inspect(child_source)}]])
        assert is_port(child)
        deadline = System.monotonic_time(:millisecond) + 2_000
        await = fn await ->
          result = with {:ok, text} <- File.read(#{inspect(portfile)}),
                        {port, ""} <- Integer.parse(String.trim(text)),
                        {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
            :ok = :gen_tcp.send(socket, "ping")
            answer = :gen_tcp.recv(socket, 0, 100)
            :gen_tcp.close(socket)
            answer
          end
          if result == {:ok, "pong"} do
            File.write!(#{inspect(readyfile)}, "private listener answered ping")
          else
            assert System.monotonic_time(:millisecond) < deadline, "owned child never answered ping"
            receive do after 10 -> await.(await) end
          end
        end
        await.(await)
        Process.sleep(:infinity)
      end
    end
    """)

    report = execute_proof(root, manifest(), timeout_ms: 3_000)
    assert [%{passed: false}] = report.executed
    assert report.proved == []

    assert File.exists?(readyfile),
           "the child must have answered its private ping before the deadline"

    port = String.to_integer(File.read!(portfile))

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500) do
      {:error, :econnrefused} ->
        :ok

      {:error, reason} ->
        flunk("cannot establish owned child closure: #{inspect(reason)}")

      {:ok, socket} ->
        :gen_tcp.close(socket)
        flunk("proof timeout left its owned child listening on #{port}")
    end
  end

  defp execute_proof(root, input \\ manifest(), opts \\ []) do
    assert Code.ensure_loaded?(Veritas.Core.Parity.Proof),
           "the archived checker has no independent executable proof implementation"

    arguments = if opts == [], do: [root, input], else: [root, input, opts]
    apply(Veritas.Core.Parity.Proof, :run, arguments)
  end

  defp proof_fixture(tag, assertion) do
    root = fixture_root()
    source = "apps/veritas_core/test/instrument_control_test.exs"
    File.mkdir_p!(Path.join(root, "apps/veritas_core/test/support"))

    File.cp!(
      Path.join(@repo, "apps/veritas_core/test/support/parity_checker_case.ex"),
      Path.join(root, "apps/veritas_core/test/support/parity_checker_case.ex")
    )

    body =
      if tag do
        """
        #{tag}
        test "runner control" do
          #{assertion}
        end
        """
      else
        ""
      end

    File.write!(Path.join(root, source), """
    defmodule Veritas.ParityRunnerControl do
      use ExUnit.Case
      #{body}
    end
    """)

    entry = %{
      id: "runner.control",
      operation: "ci.query",
      surface: "cli",
      aspect_kind: "query_mode",
      aspect: "by_type",
      file: source,
      test: "test runner control",
      mode: :elixir
    }

    write_registry(root, [entry])
    {root, entry}
  end

  defp write_registry(root, entries) do
    File.write!(Path.join(root, "apps/veritas_core/test/support/parity_proof_registry.ex"), """
    defmodule Veritas.Core.Test.ParityProofRegistry do
      def cases, do: #{inspect(entries, limit: :infinity)}
    end
    """)
  end

  defp formatter_control(tag, assertion) do
    root = fixture_root()
    File.mkdir_p!(root)
    path = Path.join(root, "runner_control.exs")

    body =
      if tag do
        """
        defmodule Veritas.ParityRunnerControl do
          use ExUnit.Case
          #{tag}
          test "runner control" do
            #{assertion}
          end
        end
        """
      else
        ""
      end

    File.write!(path, """
    ExUnit.start(autorun: false, formatters: [Veritas.Core.Test.ParityCheckerCase],
      exclude: [:test], include: [parity_proof: "runner.control"])
    #{body}
    result = ExUnit.run()
    System.halt(if result.failures == 0, do: 0, else: 1)
    """)

    {output, exit_code} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "-pa",
          Path.join(@repo, "_build/test/lib/jason/ebin"),
          "-r",
          Path.join(@repo, "apps/veritas_core/test/support/parity_checker_case.ex"),
          path
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(root, "execution.log"), output)

    events =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "VERITAS_PARITY_EVENT "))
      |> Enum.map(&(String.replace_prefix(&1, "VERITAS_PARITY_EVENT ", "") |> Jason.decode!()))

    {events, exit_code}
  end

  defp fixture_root do
    Path.join([
      @repo,
      "_build/instrument-correction-20261104/sdet/fixtures",
      Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    ])
  end

  defp assert_refused(input, argv \\ []) do
    {result, output} = check(input, argv)

    assert match?({:refused, message} when is_binary(message), result),
           "expected a diagnostic refusal, got #{inspect(result)}\n#{output}"

    {result, output}
  end

  defp check(input, argv \\ []) do
    root =
      Path.join([
        @repo,
        "_build/instrument-correction-20261104/sdet/fixtures",
        Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      ])

    path = Path.join(root, "apps/veritas_core/priv/parity/operations.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(is_binary(input), do: input, else: Jason.encode!(input)))

    result =
      try do
        Check.run(["--root", root] ++ argv)
        :ok
      rescue
        error in Mix.Error -> {:refused, Exception.message(error)}
      end

    {result, shell_output([])}
  end

  defp shell_output(messages) do
    receive do
      {:mix_shell, _level, [message]} -> shell_output([to_string(message) | messages])
    after
      0 -> messages |> Enum.reverse() |> Enum.join("\n")
    end
  end

  # Literal contract IDs above, not the shipped manifest, determine this tree.
  defp manifest do
    ids = @ticket_ids ++ @other_ids

    %{
      "meta" => %{
        "contract" => %{
          "source" => "docs/04-information-architecture-and-dashboards.md",
          "clause_line" => 479,
          "scope_line" => 481
        },
        "enumeration" => Map.new(ids, &{&1, @surfaces}),
        "coverage_states" => %{
          "missing" => "absent",
          "implemented-unverified" => "present but unproved",
          "behaviorally-verified" => "independent assertion executed"
        },
        "aspect_states" => %{
          "missing" => "absent",
          "implemented-unverified" => "unproved",
          "behaviorally-verified" => "proved",
          "open" => "unsettled",
          "not-examined" => "unexamined"
        },
        "filter_grammar" => %{
          "source" => "docs/04-information-architecture-and-dashboards.md:479",
          "applies_to" => ["ci.query", "search.global"],
          "ruling" => "not-an-operation",
          "states" => states("implemented-unverified")
        }
      },
      "operations" => Enum.map(ids, &operation/1)
    }
  end

  defp operation(id) do
    operation = %{
      "id" => id,
      "name" => id,
      "surfaces" => @surfaces,
      "ticket_types" => if(id in @ticket_ids, do: @types, else: []),
      "bindings" =>
        Map.new(@surfaces, fn surface ->
          {surface,
           %{
             "kind" => surface,
             "identifier" => "unverified:#{id}:#{surface}",
             "status" => "implemented-unverified"
           }}
        end)
    }

    cond do
      id in @ticket_ids ->
        Map.put(operation, "aspects", %{
          "kind" => "ticket_type",
          "states" => Map.new(@types, &{&1, states("implemented-unverified")})
        })

      id == "ci.query" ->
        operation
        |> Map.put("query_modes", ~w(by_attribute by_type by_relationship))
        |> Map.put("aspects", %{
          "kind" => "query_mode",
          "states" =>
            Map.new(
              ~w(by_attribute by_type by_relationship),
              &{&1, states("implemented-unverified")}
            )
        })

      id == "audit.export" ->
        operation
        |> Map.put("formats", ~w(csv jsonl))
        |> Map.put("aspects", %{
          "kind" => "format",
          "states" => Map.new(~w(csv jsonl), &{&1, states("implemented-unverified")})
        })

      true ->
        operation
    end
  end

  defp states(status), do: Map.new(@surfaces, &{&1, status})

  defp change_operation(input, id, fun) do
    Map.update!(input, "operations", fn operations ->
      Enum.map(operations, fn operation ->
        if operation["id"] == id, do: fun.(operation), else: operation
      end)
    end)
  end

  defp remove_operation(input, id) do
    input
    |> update_in(["meta", "enumeration"], &Map.delete(&1, id))
    |> Map.update!("operations", &Enum.reject(&1, fn operation -> operation["id"] == id end))
  end

  defp certify(input, identifier, location, evidence) do
    Map.update!(input, "operations", fn operations ->
      Enum.map(operations, fn operation ->
        operation =
          Map.update!(operation, "bindings", fn bindings ->
            Map.new(bindings, fn {surface, binding} ->
              {surface,
               Map.merge(binding, %{
                 "identifier" => identifier,
                 "location" => location,
                 "evidence" => evidence,
                 "status" => "behaviorally-verified"
               })}
            end)
          end)

        if operation["aspects"] do
          update_in(operation, ["aspects", "states"], fn aspects ->
            Map.new(aspects, fn {name, _} -> {name, states("behaviorally-verified")} end)
          end)
        else
          operation
        end
      end)
    end)
  end
end
