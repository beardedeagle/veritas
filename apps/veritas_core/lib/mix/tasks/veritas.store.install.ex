defmodule Mix.Tasks.Veritas.Store.Install do
  @shortdoc "Installs the SurrealDB server the node supervises"
  @moduledoc """
  Installs the `surreal` binary the node starts as its supervised child
  (ADR-048).

  The datastore is a **separate process**, not a NIF inside the BEAM: a NIF
  has to be built per target, breaks Alpine/musl, Windows and Nix, and
  couples the store's crash domain to the BEAM's. The binary is therefore
  **fetched, pinned and verified** — never taken from wherever the machine
  happens to have one, because "whatever the machine had" is exactly the
  hand-step that made the milestone unreproducible.

  ## What it does

    1. works out the platform (`darwin-arm64`, `linux-amd64`, …);
    2. takes the pinned release asset from SurrealDB's GitHub releases, or a
       local copy with `--from` for an offline install;
    3. checks the asset's SHA-256 against the digest pinned here;
    4. unpacks it into `vendor/surreal/` — the same relative path a release
       uses, so a development checkout and a release agree;
    5. checks the installed binary answers `surreal version` with the pinned
       version.

  ## No POSIX shell

  The install needs **no shell** on the host: not `shasum`, not `curl`, not
  `tar`. Each of those was a dependency on a program that exists on some
  platforms and not others — `shasum` is a BSD tool that a slim Linux image
  does not have, `curl` is often absent from a build image, and `tar` is
  absent from a Windows host altogether. The work is done by the platform
  the project already depends on:

  | Step | Was | Is |
  |---|---|---|
  | digest | `shasum -a 256` | `:crypto.hash/2` |
  | download | `curl` | `Finch`, the project's own HTTP stack |
  | unpack | `tar -xzf` | `:erl_tar` |

  The consequence is the point: the same task runs on macOS, Linux, Windows
  and Nix, on a machine with no shell tools installed at all.

  ## Usage

      mix veritas.store.install
      mix veritas.store.install --from /path/to/surreal-v3.3.4.darwin-arm64.tgz
      mix veritas.store.install --force

  ## Platforms

  The upstream release publishes gnu and darwin builds. **There is no musl
  build**, so Alpine is not covered by this task: a musl build of SurrealDB
  has to be made and pinned (`docs/10` §Packaging Matrix). The task refuses
  an unsupported platform rather than installing something that will not
  run.

  The install is **idempotent**: an already-installed binary of the pinned
  version is left alone, and `--force` replaces it.
  """

  use Mix.Task

  @version "3.3.4"

  @release_url "https://github.com/surrealdb/surrealdb/releases/download/v#{@version}"

  # The upstream release's own digests, one per published asset. The digest
  # of the **asset** is what is checked, not the digest of the binary inside
  # it, so the same table serves an offline install from a local tarball.
  @assets %{
    "darwin-amd64" => "0723b555340da2cee1e0cff6f95552438536eab8d984b91f227b3ce2d52a5006",
    "darwin-arm64" => "d0b0afc47948a46ceac9db178d2a10a7eb21e1c4f219a74b3573c850122ed9fb",
    "linux-amd64" => "6593071833ad9c85cf533cf70b1643eb08966c868f8624001e30839ea29a2689",
    "linux-arm64" => "978262fd9d1f3adfc5791031663855baf0a3cf8a89883428109734ba5a065811",
    "windows-amd64" => "1255a3b2e771b8853e9ee0aca0ddde09dbe4532248502a5d900eb3997955f0cc"
  }

  # The datastore's licence, pinned like the binary. SurrealDB is under the
  # Business Source License, and a redistribution has to carry it.
  @license_digest "98a94ac615f88370865016487b436fa404560910bd329794ed7502277a94b805"

  # The HTTP client pool the download uses. One pool, started for the task
  # and gone when the task ends.
  @pool Veritas.Store.Install.Finch

  # The chunk the digest is computed over. The asset is tens of megabytes,
  # so it is hashed as it is read rather than loaded whole.
  @chunk 64 * 1024

  # How many redirects a download may follow. A release asset is answered
  # with one redirect to the CDN; the bound is there so a redirect loop is
  # an error rather than a hang.
  @max_redirects 5

  @impl true
  def run(argv) do
    # The pool is started for the task and is gone when the task ends.
    _pool = start_pool()

    {opts, _rest} = OptionParser.parse!(argv, strict: [from: :string, force: :boolean])

    target = target()
    Mix.shell().info("Veritas #{@version} datastore, platform #{target}")

    case Map.fetch(@assets, target) do
      {:ok, digest} ->
        install(target, digest, opts)

      :error ->
        Mix.raise("""
        Veritas has no pinned SurrealDB build for #{target}.

        The upstream release publishes #{Enum.join(Map.keys(@assets), ", ")} and
        nothing else — in particular there is no musl build, so Alpine is not
        covered by this task. See docs/10 §Packaging Matrix.
        """)
    end
  end

  # ── the install ─────────────────────────────────────────────────────────────

  defp install(target, digest, opts) do
    target_path = Path.join(vendor_dir(), binary_name(target))

    if installed?(target_path) and opts[:force] != true do
      # The licence is ensured every time: a binary without it is a
      # redistribution without it.
      install_license!()
      Mix.shell().info("already installed: #{target_path}")
      :ok
    else
      asset = fetch(target, digest, opts)
      verify!(asset, digest)
      unpack(asset, target, target_path)
      check_version!(target_path)
      install_license!()
      Mix.shell().info("installed: #{target_path}")
      :ok
    end
  end

  # The licence travels with the binary: SurrealDB is under the Business
  # Source License, and a redistribution has to carry it.
  defp install_license! do
    path = Path.join(vendor_dir(), "LICENSE")

    if File.exists?(path) do
      :ok
    else
      url = "#{@release_url}/LICENSE"
      Mix.shell().info("downloading #{url}")

      body = http_get!(url)
      verify_bytes!(body, @license_digest, url)

      File.mkdir_p!(vendor_dir())
      File.write!(path, body)
      :ok
    end
  end

  defp fetch(target, _digest, opts) do
    case opts[:from] do
      nil -> download(target)
      path -> local(path)
    end
  end

  defp download(target) do
    url = "#{@release_url}/surreal-v#{@version}.#{target}#{archive_suffix(target)}"
    Mix.shell().info("downloading #{url}")

    path = Path.join(System.tmp_dir!(), "surreal-v#{@version}.#{target}#{archive_suffix(target)}")

    http_download!(url, path)
    path
  end

  defp local(path) do
    unless File.exists?(path) do
      Mix.raise("there is no file at #{path}")
    end

    Mix.shell().info("using #{path}")
    path
  end

  # The digest is checked before anything is unpacked. A binary that is not
  # the pinned one is never written to disk.
  defp verify!(path, digest) do
    actual = sha256(path)

    if actual != digest do
      Mix.raise("""
      the digest does not match.

        expected #{digest}
        actual   #{actual}

      The download is not the pinned release, and it has not been installed.
      """)
    end

    Mix.shell().info("digest verified: #{digest}")
  end

  defp unpack(asset, target, target_path) do
    File.mkdir_p!(Path.dirname(target_path))

    case target do
      "windows-amd64" ->
        replace!(target_path, asset)

      _unix ->
        extract(asset, target_path)
    end

    File.chmod!(target_path, 0o755)
  end

  # Whatever is at the target is replaced, so the install leaves the pinned
  # binary and not a leftover — and it replaces the *path*, rather than
  # writing through it, so a symlink at that path is removed instead of
  # being followed to whatever it points at.
  defp replace!(target_path, source) do
    case File.rm_rf(target_path) do
      {:ok, _removed} ->
        File.cp!(source, target_path)

      {:error, reason, file} ->
        Mix.raise(
          "the file at #{target_path} could not be replaced (#{inspect(reason)}): #{file}"
        )
    end
  end

  # The archive is unpacked with `:erl_tar`, which reads the same tar format
  # `tar` does and needs no program on the host. It is unpacked into a
  # staging directory rather than beside the target, so an archive cannot
  # scatter files across `vendor/surreal/`, and so the one file the project
  # wants is the one that is taken.
  defp extract(asset, target_path) do
    staging =
      Path.join(
        System.tmp_dir!(),
        "veritas-store-unpack-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(staging)

    try do
      member = binary_member!(asset)
      name = to_string(member)

      case :erl_tar.extract(String.to_charlist(asset), [
             :compressed,
             {:cwd, String.to_charlist(staging)}
           ]) do
        :ok ->
          :ok

        {:error, reason} ->
          Mix.raise("the asset could not be unpacked: #{:erl_tar.format_error(reason)}")
      end

      extracted = Path.join(staging, name)

      unless File.exists?(extracted) do
        Mix.raise("the asset does not carry #{name}")
      end

      replace!(target_path, extracted)
    after
      File.rm_rf(staging)
    end
  end

  # The member of the archive that is the datastore's binary. The archive
  # carries it at the top level; anything else in it is not what the node
  # runs, and is not installed.
  defp binary_member!(asset) do
    case :erl_tar.table(String.to_charlist(asset), [:compressed]) do
      {:ok, members} ->
        names = Enum.map(members, &to_string/1)

        case Enum.find(names, &(Path.basename(&1) == "surreal")) do
          nil ->
            Mix.raise("""
            the asset does not carry the datastore's binary.

              members: #{Enum.join(names, ", ")}

            It is not the pinned release, and it has not been installed.
            """)

          name ->
            name
        end

      {:error, reason} ->
        Mix.raise("the asset is not a readable archive: #{:erl_tar.format_error(reason)}")
    end
  end

  # The installed binary is asked what it is. A binary that does not answer
  # with the pinned version is not the one that was pinned.
  defp check_version!(path) do
    {output, status} = System.cmd(path, ["version"], stderr_to_stdout: true)

    unless status == 0 and String.contains?(output, @version) do
      Mix.raise("""
      the installed binary does not report the pinned version.

        expected a version containing #{@version}
        actual   #{String.trim(output)}

      It has not been used and the install should be repeated.
      """)
    end

    Mix.shell().info("version verified: #{String.trim(output)}")
  end

  defp installed?(path) do
    case File.stat(path) do
      {:ok, _stat} -> true
      {:error, _reason} -> false
    end
  end

  # ── the platform ────────────────────────────────────────────────────────────

  # The platform key is the upstream release's own name for the asset, so
  # there is no mapping table to keep in step with the release.
  defp target do
    {_family, os} = :os.type()

    case {os, arch()} do
      {:darwin, "arm64"} -> "darwin-arm64"
      {:darwin, "amd64"} -> "darwin-amd64"
      {:linux, "arm64"} -> "linux-arm64"
      {:linux, "amd64"} -> "linux-amd64"
      {:nt, "amd64"} -> "windows-amd64"
      {other, architecture} -> Mix.raise("Veritas does not run on #{other}/#{architecture}")
    end
  end

  # `:erlang.system_info/1` answers with a charlist.
  defp arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "aarch64" <> _ -> "arm64"
      "x86_64" <> _ -> "amd64"
      other -> Mix.raise("Veritas has no pinned build for the architecture #{other}")
    end
  end

  defp archive_suffix("windows-amd64"), do: ".exe"
  defp archive_suffix(_target), do: ".tgz"

  defp binary_name("windows-amd64"), do: "surreal.exe"
  defp binary_name(_target), do: "surreal"

  # ── the paths ───────────────────────────────────────────────────────────────

  # The same relative path a release uses, so the development checkout and
  # the release agree on where the binary is.
  defp vendor_dir do
    Path.join(project_root(), "vendor/surreal")
  end

  defp project_root do
    Path.expand("../../../../..", __DIR__)
  end

  # ── the digest ──────────────────────────────────────────────────────────────

  # The digest is computed by `:crypto`, over the file as it is read. No
  # external program is involved, so the digest is the same on every
  # platform the project runs on.
  defp sha256(path) do
    state = :crypto.hash_init(:sha256)

    state =
      path
      |> File.stream!(@chunk, [])
      |> Enum.reduce(state, &:crypto.hash_update(&2, &1))

    state
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp verify_bytes!(body, digest, source) do
    actual = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

    if actual != digest do
      Mix.raise("""
      the digest does not match.

        expected #{digest}
        actual   #{actual}
        source   #{source}

      It is not the pinned file, and it has not been installed.
      """)
    end

    Mix.shell().info("digest verified: #{digest}")
  end

  # ── the HTTP ───────────────────────────────────────────────────────────────

  # The download goes through `Finch`, the project's own HTTP stack. The
  # asset is tens of megabytes, so it is streamed to the file rather than
  # held in memory.
  #
  # A release asset is answered with a **redirect** to the CDN that serves
  # it, and `curl --location` followed it. Finch does not follow redirects,
  # so the task does: a redirect is followed, up to a bound, and the target
  # may be another host — the CDN is not the host the release is on.
  defp http_download!(url, path) do
    case follow(url, @max_redirects, fn target -> stream_to(target, path) end) do
      :ok ->
        :ok

      {:redirect, _location} ->
        Mix.raise("the download was redirected too many times:\n#{url}")

      {:error, reason} ->
        Mix.raise("the download failed (#{inspect(reason)}):\n#{url}")
    end
  end

  defp http_get!(url) do
    case follow(url, @max_redirects, &get/1) do
      {:ok, body} ->
        body

      {:redirect, _location} ->
        Mix.raise("the download was redirected too many times:\n#{url}")

      {:error, reason} ->
        Mix.raise("the download failed (#{inspect(reason)}):\n#{url}")
    end
  end

  # The redirect chain, bounded. Each hop is a fresh request to the URL the
  # last answer pointed at.
  defp follow(url, redirects_left, request) do
    case request.(url) do
      {:redirect, location} when redirects_left > 0 ->
        follow(redirect_url(url, location), redirects_left - 1, request)

      other ->
        other
    end
  end

  defp redirect_url(url, location) do
    url
    |> URI.parse()
    |> URI.merge(location)
    |> URI.to_string()
  end

  defp stream_to(url, path) do
    request = Finch.build(:get, url)
    file = File.open!(path, [:write, :binary])

    result =
      try do
        Finch.stream(request, @pool, %{status: nil, location: nil}, fn
          {:status, status}, acc ->
            %{acc | status: status}

          {:headers, headers}, acc ->
            %{acc | location: header(headers, "location")}

          {:trailers, headers}, acc ->
            %{acc | location: header(headers, "location")}

          {:data, data}, acc ->
            :ok = IO.binwrite(file, data)
            acc

          # The HTTP/1 pool hands the headers over as the fields it has
          # seen so far and the ones this answer added, rather than as one
          # tagged list.
          {fields, values}, acc when is_list(fields) and is_list(values) ->
            %{acc | location: header(fields ++ values, "location")}
        end)
      after
        File.close(file)
      end

    case result do
      {:ok, %{status: status, location: location}}
      when status in 300..399 and is_binary(location) ->
        {:redirect, location}

      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason, _acc} ->
        {:error, reason}
    end
  end

  defp get(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, @pool, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: status, headers: headers}} when status in 300..399 ->
        case header(headers, "location") do
          nil -> {:error, {:http_status, status}}
          location -> {:redirect, location}
        end

      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A header, by name. The names are case-insensitive on the wire, the
  # server's own capitalisation is not a contract, and the value arrives as
  # a string in either case.
  defp header(headers, name) do
    Enum.find_value(headers, fn
      {header, value} ->
        if String.downcase(to_string(header)) == name, do: to_string(value)

      _other ->
        nil
    end)
  end

  # The pool is started for the task and is gone when the task ends. It is
  # linked to this process, so nothing outlives the install.
  defp start_pool do
    {:ok, _apps} = Application.ensure_all_started(:finch)

    case Finch.start_link(name: @pool) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
