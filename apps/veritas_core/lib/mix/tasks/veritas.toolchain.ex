defmodule Mix.Tasks.Veritas.Toolchain do
  @moduledoc """
  Checks that the toolchain running this build is the toolchain the project is
  pinned to.

      mix veritas.toolchain

  The pin is `.tool-versions` at the root of the repository: the Elixir version
  exactly, and the Erlang/OTP release line. This task compares what is running
  against that file and fails when they differ.

  Why it is a gate and not a convenience: a build on a different toolchain is a
  different build. A pipeline that installs one version and asserts another
  proves nothing, and the two of them do not produce the same artefact. The
  rule is stated in `docs/11` §Toolchain and Version Pinning; this task is the
  check that enforces it, and the pipeline runs it before anything else.

  The comparison is deliberately asymmetric. Elixir is compared exactly, because
  a patch of Elixir is a different compiler. Erlang/OTP is compared by release
  line, because the security fixes land on the newest patch of the line and a
  patch-pinned Erlang would age out of the security window the moment a new
  patch shipped. The pipeline logs the exact patch it installed.
  """

  use Mix.Task

  @shortdoc "Checks the running toolchain against the pin in .tool-versions"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [quiet: :boolean])

    root = project_root()
    pins = read_pins!(root)

    running = %{
      elixir: System.version(),
      erlang: System.otp_release()
    }

    drift =
      []
      |> compare(:elixir, pins[:elixir], running[:elixir], "Elixir")
      |> compare(:erlang, pins[:erlang], running[:erlang], "Erlang/OTP release")

    unless opts[:quiet] do
      Mix.shell().info("toolchain")
      Mix.shell().info("  pinned   Elixir #{pins[:elixir]}, Erlang/OTP #{pins[:erlang]}")
      Mix.shell().info("  running  Elixir #{running[:elixir]}, Erlang/OTP #{running[:erlang]}")
    end

    if drift == [] do
      unless opts[:quiet], do: Mix.shell().info("the toolchain matches the pin")
      :ok
    else
      Mix.raise("""
      the toolchain does not match the pin in .tool-versions.

      #{Enum.map_join(drift, "\n", fn line -> "  * #{line}" end)}

      A build on a different toolchain is a different build, and the artefacts
      are not the same artefact. Install the pinned toolchain — the file names
      the versions — and run this again.
      """)
    end
  end

  defp compare(drift, key, pinned, running, label) do
    if is_nil(pinned) do
      drift
    else
      case key do
        :elixir ->
          if pinned == running do
            drift
          else
            drift ++ ["#{label} is #{running} and the pin is #{pinned}"]
          end

        :erlang ->
          if String.starts_with?(running, pinned) do
            drift
          else
            drift ++ ["#{label} is #{running} and the pin is the #{pinned} line"]
          end
      end
    end
  end

  @doc """
  The directory holding `.tool-versions`, found by walking up from the current
  directory. The task runs from the umbrella root and from each application,
  so the answer is not the same either way.
  """
  @spec project_root() :: Path.t()
  def project_root do
    Path.expand(".")
    |> find_root()
    |> case do
      nil ->
        Mix.raise(
          "no .tool-versions found above #{Path.expand(".")}. " <>
            "The toolchain pin belongs at the root of the repository."
        )

      root ->
        root
    end
  end

  defp find_root(dir) do
    if File.exists?(Path.join(dir, ".tool-versions")) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        nil
      else
        find_root(parent)
      end
    end
  end

  defp read_pins!(root) do
    path = Path.join(root, ".tool-versions")

    pins =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(String.trim(line, "# "), ~r/\s+/, trim: true) do
          [name, version] -> Map.put(acc, String.to_atom(name), version)
          _ -> acc
        end
      end)

    for {name, key} <- [elixir: :elixir, erlang: :erlang] do
      unless Map.has_key?(pins, key) do
        Mix.raise("#{path} does not pin #{name}")
      end
    end

    pins
  end
end
