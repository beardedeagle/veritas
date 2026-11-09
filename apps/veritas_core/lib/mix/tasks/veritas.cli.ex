defmodule Mix.Tasks.Veritas.Cli do
  @moduledoc """
  The command-line surface.

  The third surface over one service layer (INV-8). Every operation here is
  also available in the LiveView UI and over GraphQL, and all three call
  `Veritas.Core` — none of them talks to the datastore directly.

  ## Usage

      mix veritas.cli tickets --workspace default [--type incident] [--state new]
      mix veritas.cli show --workspace default --id <ticket-id>
      mix veritas.cli open --workspace default --type incident --title "..." --requester <user-id>
      mix veritas.cli transition --workspace default --id <ticket-id> --to-state acknowledged --as <account-email>
      mix veritas.cli update --workspace default --id <ticket-id> [--title "..."] [--description "..."] --actor <user-id>
      mix veritas.cli impact --workspace default --ci <ci-id> [--depth 2]
      mix veritas.cli ci list --workspace default [--type T] [--lifecycle S] [--criticality C]
      mix veritas.cli ci show --workspace default --id <ci-id>
      mix veritas.cli ci create --workspace default --type server --name "web-01" --attr region=eu-west-1
      mix veritas.cli ci relate --workspace default --from web-01 --kind runs_on --to db-01
      mix veritas.cli ci seed --workspace default
      mix veritas.cli account bootstrap-token --workspace default
      mix veritas.cli account create --workspace default --email <email> --password <password> --role platform_admin
      mix veritas.cli account set-password --workspace default --email <email> --password <password> --as <operator-email>
      mix veritas.cli workflow template --type incident
      mix veritas.cli workflow save --workspace default --file workflow.json [--id ID --revision N]
      mix veritas.cli workflow publish --workspace default --id ID --revision N
      mix veritas.cli workflow start --workspace default --id ID --file intake.json
      mix veritas.cli workflow complete --workspace default --id TICKET --revision N [--file answers.json] [--next STEP] [--approve]
      mix veritas.cli audit verify --workspace default
      mix veritas.cli migrate
      mix veritas.cli doctor

  Add `--json` to any command for machine-readable output.

  The password may be given in `VERITAS_ACCOUNT_PASSWORD` instead of on the
  command line, so that it need not appear in a shell's history. It is never
  echoed. The operator's account defaults to `VERITAS_OPERATOR_EMAIL`;
  an explicit `--as` takes precedence. The operator's own password is read
  from `VERITAS_OPERATOR_PASSWORD`.

  A bootstrap token is never taken on the command line, because a command
  line is readable by every process on the machine. It is read from the
  `VERITAS_BOOTSTRAP_TOKEN` environment variable, from standard input
  (`--bootstrap-token-stdin`), from a file (`--bootstrap-token-file`), or
  from a masked prompt.

  `account bootstrap-token --copy` also requests a clipboard copy. If the
  clipboard is unavailable, issuance still succeeds: the private token file
  remains usable, the text report says so, and JSON reports `copied: false`.

  ## Exit codes

  The exit code is the honest part of the interface: a script must be able to
  tell a refusal from a broken store.

  | Code | Meaning |
  | --- | --- |
  | 0 | success |
  | 1 | usage error — the command or its arguments are wrong |
  | 2 | the domain refused the operation (unknown ticket, illegal transition, not found) |
  | 3 | the datastore failed (unavailable, timeout, conflict, unsupported) |
  | 4 | the Audit Log chain is broken |
  | 5 | the doctor found a fault |

  The datastore URL comes from `VERITAS_SURREAL_URL` (default
  `http://127.0.0.1:8000`).
  """

  use Mix.Task

  alias Veritas.Core.{Audit, CI, Policy, Principal, Tickets}
  alias Veritas.Store
  alias Veritas.Store.Error

  @shortdoc "Veritas command line"

  @exit_ok 0
  @exit_usage 1
  @exit_refused 2
  @exit_store 3
  @exit_chain 4
  @exit_unhealthy 5

  @impl Mix.Task
  def run(args) do
    # A Mix task does not start the applications by itself, and the store
    # adapter needs the HTTP client pool.
    # The command line is a **client** of a store, not a node that owns one:
    # it reaches the store the operator configured, and it does not start a
    # datastore of its own behind their back.
    System.put_env("VERITAS_ROLE", "cli")
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          id: :string,
          type: :string,
          state: :string,
          title: :string,
          description: :string,
          requester: :string,
          priority: :string,
          to_state: :string,
          actor: :string,
          ci: :string,
          depth: :integer,
          name: :string,
          lifecycle: :string,
          criticality: :string,
          owner: :string,
          from: :string,
          to: :string,
          kind: :string,
          attr: :keep,
          reason: :string,
          limit: :integer,
          email: :string,
          password: :string,
          role: :keep,
          as: :string,
          actor: :string,
          bootstrap_token_stdin: :boolean,
          bootstrap_token_file: :string,
          file: :string,
          copy: :boolean,
          json: :boolean,
          revision: :integer,
          domain_revision: :string,
          policy_revision: :string,
          policy_version: :string,
          domain_file: :string,
          next: :string,
          approve: :boolean,
          model: :string,
          prompt: :string
        ],
        aliases: [w: :workspace, i: :id, t: :type, s: :state]
      )

    opts =
      Keyword.put_new_lazy(opts, :as, fn ->
        System.get_env("VERITAS_OPERATOR_EMAIL", "") |> String.trim() |> present()
      end)

    json? = opts[:json] == true

    # A removed option is refused, not ignored: an operator who passes it
    # must be told, because a command line is readable by every process on
    # the machine and the token has to come from somewhere else.
    if List.keymember?(invalid, "--bootstrap-token", 0) or
         List.keymember?(invalid, "bootstrap_token", 0) do
      usage_error(
        "--bootstrap-token has been removed: a command line is readable by every " <>
          "process on the machine. The token is read from #{Veritas.Core.BootstrapToken.token_env_var()}, " <>
          "from standard input (--bootstrap-token-stdin), from a file " <>
          "(--bootstrap-token-file), or from a masked prompt.",
        json?
      )
    end

    if match?(["workflow" | _], positional) and invalid != [] do
      names = Enum.map_join(invalid, ", ", fn {name, _} -> name end)
      usage_error("Unknown workflow option: #{names}", json?)
    end

    dispatch(positional, opts, json?)
  end

  # The verb, and the command it runs.
  #
  # The dispatch is its own function so that the table of verbs can grow
  # without the entry point growing with it: the complexity limit is a
  # ratchet, and a verb added to the table must not push the function that
  # reads the command line past it.
  defp dispatch(positional, opts, json?) do
    case positional do
      ["tickets"] -> tickets(opts, json?)
      ["show"] -> show(opts, json?)
      ["open"] -> open(opts, json?)
      ["transition"] -> transition(opts, json?)
      ["update"] -> update(opts, json?)
      ["impact"] -> impact(opts, json?)
      ["ci", subcommand] -> ci(subcommand, opts, json?)
      ["chain-key", subcommand] -> chain_key(subcommand, opts, json?)
      ["account", subcommand] -> account(subcommand, opts, json?)
      ["workflow", subcommand] -> workflow(subcommand, opts, json?)
      ["incident", subcommand] -> incident(subcommand, opts, json?)
      ["incident-policy", subcommand] -> incident_policy(subcommand, opts, json?)
      ["audit", "verify"] -> verify(opts, json?)
      ["migrate"] -> migrate(opts, json?)
      ["doctor"] -> doctor(opts, json?)
      _ -> usage()
    end
  end

  defp workspace(opts), do: opts[:workspace] || "default"

  defp workflow("template", opts, _json?) do
    emit_json(Veritas.Core.Workflows.template(opts[:type] || "incident"))
    exit({:shutdown, @exit_ok})
  end

  defp workflow(command, opts, json?)
       when command in ~w(list show save publish start run complete draft generate) do
    workflow_options!(command, opts, json?)

    workspace = workspace(opts)
    principal = operator_principal(workspace, opts[:as], json?)
    id = opts[:id] || ""

    input = workflow_input(opts[:file], json?)

    result =
      case command do
        "list" ->
          Veritas.Core.Workflows.list(workspace, principal)

        "show" ->
          Veritas.Core.Workflows.get(workspace, id, principal)

        "save" ->
          Veritas.Core.Workflows.save(workspace, opts[:id], input, principal,
            expected_revision: opts[:revision]
          )

        "publish" ->
          Veritas.Core.Workflows.publish(workspace, id, opts[:revision], principal)

        "start" ->
          Veritas.Core.Workflows.start(workspace, id, input, principal)

        "run" ->
          Veritas.Core.Workflows.run(workspace, id, principal)

        "complete" ->
          Veritas.Core.Workflows.complete(workspace, id, input, principal,
            incident_opts(opts, json?) ++ [next: opts[:next], approve: opts[:approve],
              domain_fields: workflow_input(opts[:domain_file], json?)]
          )

        "draft" ->
          Veritas.Core.Workflows.draft(workspace, id, principal, model: opts[:model])

        "generate" ->
          Veritas.Core.Workflows.generate(
            workspace,
            opts[:prompt] || "",
            opts[:type] || "incident",
            principal,
            model: opts[:model]
          )

        _ ->
          usage_error(
            "workflow expects template, list, show, save, publish, start, run, complete, draft or generate",
            json?
          )
      end

    workflow_result(result, command, json?)
  end

  defp workflow(_, _opts, json?),
    do:
      usage_error(
        "workflow expects template, list, show, save, publish, start, run, complete, draft or generate",
        json?
      )

  defp workflow_input(nil, _json?), do: %{}

  defp workflow_input(file, json?) do
    with {:ok, text} <- File.read(file), {:ok, %{} = value} <- Jason.decode(text) do
      value
    else
      _ -> usage_error("--file must name a readable JSON object", json?)
    end
  end

  defp workflow_result(result, command, json?) do
    case result do
      {:ok, value} ->
        if json?,
          do: emit_json(%{result: value}),
          else: Mix.shell().info(Jason.encode!(value, pretty: true))

        exit({:shutdown, @exit_ok})

      {:error, %Error{} = reason} ->
        store_error(reason, json?)

      {:error, reason} ->
        safe = Error.public(reason)
        refuse(safe.message, json?, Map.put(safe, :command, command))
    end
  end

  defp workflow_options!(command, opts, json?) do
    if opts[:actor],
      do: usage_error("workflow commands use --as or VERITAS_OPERATOR_EMAIL, not --actor", json?)

    required =
      case command do
        "save" -> [:file] ++ if(opts[:id], do: [:revision], else: [])
        "start" -> [:id, :file]
        verb when verb in ~w(publish complete) -> [:id, :revision]
        verb when verb in ~w(show run draft) -> [:id]
        "generate" -> [:prompt]
        _ -> []
      end

    Enum.each(required, fn option ->
      value = opts[option]

      valid =
        if option == :revision,
          do: is_integer(value) and value > 0,
          else: is_binary(value) and String.trim(value) != ""

      unless valid,
        do: usage_error("workflow #{command} needs --#{option} with a valid value", json?)
    end)
  end

  defp incident(command, opts, json?) when command in ~w(show update) do
    principal = operator_principal(workspace(opts), opts[:as], json?)
    id = opts[:id] || usage_error("incident needs --id", json?)
    result = case command do
      "show" -> Tickets.read_domain(workspace(opts), id, principal)
      "update" ->
        unless opts[:file], do: usage_error("incident update needs --file", json?)
        Tickets.update_domain(workspace(opts), id, workflow_input(opts[:file], json?),
          principal, incident_opts(opts, json?))
    end
    workflow_result(result, "incident #{command}", json?)
  end
  defp incident(_, _, json?), do: usage_error("incident expects show or update", json?)

  defp incident_policy(command, opts, json?) when command in ~w(show validate save publish) do
    principal = operator_principal(workspace(opts), opts[:as], json?)
    if command in ~w(validate save) and is_nil(opts[:file]),
      do: usage_error("incident-policy #{command} needs --file", json?)
    if command in ~w(save publish) and not Keyword.has_key?(opts, :policy_revision),
      do: usage_error("Use --policy-revision N, or null for no configuration row", json?)
    result = case command do
      "show" -> Tickets.incident_policy(workspace(opts), principal)
      "validate" -> Tickets.validate_incident_policy(workspace(opts), workflow_input(opts[:file], json?), principal)
      "save" -> Tickets.save_incident_policy(workspace(opts), workflow_input(opts[:file], json?),
        principal, nullable_revision(opts[:policy_revision], json?))
      "publish" -> Tickets.publish_incident_policy(workspace(opts), principal,
        nullable_revision(opts[:policy_revision], json?), incident_opts(opts, json?) ++ [approve: opts[:approve] == true])
    end
    workflow_result(result, "incident-policy #{command}", json?)
  end
  defp incident_policy(_, _, json?),
    do: usage_error("incident-policy expects show, validate, save or publish", json?)

  # Presence is preserved: an omitted option never becomes an explicit nil CAS.
  defp incident_opts(opts, json?) do
    base = Keyword.take(opts, [:reason])
    base = if Keyword.has_key?(opts, :revision),
      do: Keyword.put(base, :expected_revision, opts[:revision]), else: base
    base = if Keyword.has_key?(opts, :domain_revision),
      do: Keyword.put(base, :expected_domain_revision, nullable_revision(opts[:domain_revision], json?)), else: base
    if Keyword.has_key?(opts, :policy_version),
      do: Keyword.put(base, :expected_policy_version, if(opts[:policy_version] == "null", do: nil, else: opts[:policy_version])),
      else: base
  end

  defp nullable_revision("null", _json?), do: nil
  defp nullable_revision(value, json?) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} when revision > 0 -> revision
      _ -> usage_error("Revision must be a positive integer or null", json?)
    end
  end
  defp nullable_revision(_, json?), do: usage_error("Revision must be a positive integer or null", json?)

  # ── commands ──────────────────────────────────────────────────────────────

  defp tickets(opts, json?) do
    filters =
      []
      |> put_opt(:ticket_type, opts[:type])
      |> put_opt(:state, opts[:state])

    case Tickets.list(workspace(opts), filters) do
      {:ok, rows} ->
        if json? do
          emit_json(%{tickets: rows})
        else
          Mix.shell().info("ID                    TYPE         STATE        PRIORITY   TITLE")

          Enum.each(rows, fn row ->
            Mix.shell().info(
              String.pad_trailing(bare_id(row["id"]), 21) <>
                String.pad_trailing(to_string(row["ticket_type"]), 13) <>
                String.pad_trailing(to_string(row["state"]), 13) <>
                String.pad_trailing(to_string(row["priority"]), 10) <>
                to_string(row["title"])
            )
          end)
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  defp show(opts, json?) do
    case Tickets.read(workspace(opts), opts[:id] || "") do
      {:ok, nil} ->
        refuse("no such ticket", json?, %{id: opts[:id]})

      {:ok, row} ->
        if json? do
          emit_json(%{ticket: row})
        else
          Mix.shell().info(Jason.encode!(row, pretty: true))
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  defp open(opts, json?) do
    type = opts[:type] || "incident"
    principal = operator_principal(workspace(opts), opts[:as], json?)
    attrs = %{"title" => opts[:title] || "(untitled)",
      "description" => opts[:description] || "", "requester" => opts[:requester] || principal.id,
      "domain_fields" => workflow_input(opts[:domain_file], json?)}
    attrs = cond do
      Keyword.has_key?(opts, :priority) -> Map.put(attrs, "priority", opts[:priority])
      type != "incident" -> Map.put(attrs, "priority", "medium")
      true -> attrs
    end

    case Tickets.open(workspace(opts), type, attrs, principal, Principal.audit_actor(principal),
           incident_opts(opts, json?)) do
      {:ok, row} ->
        if json? do
          emit_json(%{ticket: row})
        else
          Mix.shell().info("opened #{row["id"]} in state #{row["state"]}")
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        public_failure(reason, json?)
    end
  end

  defp transition(opts, json?) do
    if opts[:actor], do: usage_error("transition uses --as, not --actor", json?)
    principal = operator_principal(workspace(opts), opts[:as], json?)

    case Tickets.transition(workspace(opts), opts[:id] || "", opts[:to_state] || "", principal,
           Principal.audit_actor(principal), incident_opts(opts, json?) ++
             [domain_fields: workflow_input(opts[:domain_file], json?)]) do
      {:ok, row} ->
        if json? do
          emit_json(%{ticket: row})
        else
          Mix.shell().info("#{row["id"]} is now #{row["state"]}")
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} when is_binary(reason) ->
        public_failure(reason, json?)

      {:error, %Error{} = reason} ->
        store_error(reason, json?)

      {:error, reason} ->
        public_failure(reason, json?)
    end
  end

  defp update(opts, json?) do
    principal = operator_principal(workspace(opts), opts[:as], json?)

    case Tickets.update(workspace(opts), opts[:id] || "", update_attrs(opts), principal,
           Principal.audit_actor(principal), incident_opts(opts, json?)) do
      {:ok, row} ->
        if json? do
          emit_json(%{ticket: row})
        else
          Mix.shell().info("updated #{row["id"]}")
        end

        exit({:shutdown, @exit_ok})

      {:error, %Error{} = reason} ->
        store_error(reason, json?)

      {:error, reason} ->
        public_failure(reason, json?)
    end
  end

  # Every ticket field the operator named, and nothing else.
  #
  # Which fields an update owns is the domain's to say, so the CLI hands over
  # what it was given and lets the domain refuse the rest **by name**. A field
  # the CLI dropped on the floor would leave the operator believing the ticket
  # changed when it did not.
  defp update_attrs(opts) do
    []
    |> put_opt(:title, opts[:title])
    |> put_opt(:description, opts[:description])
    |> put_opt(:state, opts[:state])
    |> put_opt(:priority, opts[:priority])
    |> put_opt(:requester, opts[:requester])
    |> put_opt(:to_state, opts[:to_state])
    |> Map.new()
  end

  defp impact(opts, json?) do
    # The CMDB's question, asked of the CMDB's domain: the CLI must not answer
    # it from a narrower path than the UI and the API do.
    case CI.impact(workspace(opts), opts[:ci] || "", opts[:depth] || 2) do
      {:ok, result} ->
        if json? do
          emit_json(%{
            ci: result[:ci] && result[:ci]["id"],
            dependents: Enum.map(result[:dependents] || [], & &1["id"]),
            services: Enum.map(result[:services] || [], & &1["id"]),
            tickets: Enum.map(result[:tickets] || [], & &1["id"])
          })
        else
          Mix.shell().info(Jason.encode!(result, pretty: true))
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  defp verify(opts, json?) do
    case Audit.verify(workspace(opts)) do
      {:ok, :intact} ->
        if json? do
          emit_json(%{audit: %{workspace: workspace(opts), intact: true}})
        else
          Mix.shell().info("audit chain intact")
        end

        exit({:shutdown, @exit_ok})

      {:ok, {:broken_at, index}} ->
        if json? do
          emit_json(%{audit: %{workspace: workspace(opts), intact: false, broken_at: index}})
        else
          Mix.shell().error("audit chain broken at event #{index}")
        end

        exit({:shutdown, @exit_chain})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  defp migrate(opts, json?) do
    case Store.adapter().migrate(workspace(opts)) do
      :ok ->
        if json? do
          emit_json(%{
            migrate: %{
              workspace: workspace(opts),
              version: Store.adapter().migration_version()
            }
          })
        else
          Mix.shell().info(
            "schema applied to workspace #{workspace(opts)} (version #{Store.adapter().migration_version()})"
          )
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  # ── the chain key ──────────────────────────────────────────────────────────
  #
  # Turning the key is one operator action, and it is audited. The ring is
  # turned, the Workspace's chain is re-signed under the new key, and the act
  # is written into that chain — because a re-sign changes the chain's bytes
  # and its head, and an operator reading the chain a year later has to be
  # able to see that it was re-signed rather than only extended.
  #
  # The retired key stays in the ring: the events it signed are still in
  # some chains, and a key that is dropped while that is true makes them
  # unverifiable rather than verified.

  defp chain_key("rotate", _opts, json?) do
    case Veritas.Core.Audit.ChainKey.rotate() do
      {:ok, %{from: from, to: to}} ->
        if json? do
          emit_json(%{chain_key: %{from: from, to: to, rotated: true}})
        else
          Mix.shell().info(
            "the chain key was rotated from #{from} to #{to}; the key it replaced stays in the ring."
          )

          Mix.shell().info(
            "Adopt it into each workspace's chain with `mix veritas.cli chain-key adopt --workspace <workspace>`."
          )
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        refuse(reason_text(reason), json?, %{code: :refused})
    end
  end

  defp chain_key("adopt", opts, json?) do
    workspace = workspace(opts)
    actor = opts[:actor] || "operator"

    case Veritas.Core.Audit.resign_chain(workspace, actor: actor) do
      {:ok, _event} ->
        if json? do
          emit_json(%{chain_key: %{workspace: workspace, adopted: true, audited: true}})
        else
          Mix.shell().info(
            "the chain of #{workspace} was re-signed under the current key and the adoption recorded in its Audit Log."
          )
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  defp chain_key(_subcommand, _opts, _json?), do: usage()

  # A reason may be a string or an error tuple; the CLI prints a message.
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: "the chain key could not be rotated: #{inspect(reason)}"

  # ── the accounts ───────────────────────────────────────────────────────────
  #
  # The operator's path to a local account.
  #
  # `docs/09` §3: there is no self-service reset — the operator resets via
  # the CLI on the Node, and the reset is written to the Audit Log. §12
  # says what a fresh install has: a bootstrap administrator created from a
  # one-time token printed to the console and never stored.
  #
  # So there are two ways in, and they are different:
  #
  #   * **the bootstrap path** — the Workspace has no accounts yet, so there
  #     is no Principal to ask. The one-time token is the authority, and it
  #     is consumed by the account it creates.
  #   * **the operator path** — the caller names the account they act as
  #     (`--as`), and `Veritas.Core.Policy` decides whether that Principal
  #     may administer the Workspace. The Policy's Workspace rule means an
  #     operator can only administer the Workspace they act in.
  #
  # The password is never echoed: not in the success line, not in an error,
  # not in the JSON. It may be given in `VERITAS_ACCOUNT_PASSWORD` so that
  # it need not appear in a shell's history.

  defp account("create", opts, json?) do
    workspace = workspace(opts)
    email = opts[:email]
    password = secret(opts[:password], "VERITAS_ACCOUNT_PASSWORD")

    case role_names(opts[:role]) do
      {:ok, []} ->
        usage_error("account create needs at least one --role", json?)

      {:ok, _roles} when is_nil(email) ->
        usage_error("account create needs --email", json?)

      {:ok, _roles} when is_nil(password) ->
        usage_error(
          "account create needs --password, or VERITAS_ACCOUNT_PASSWORD in the environment",
          json?
        )

      {:ok, roles} ->
        with_authority(workspace, opts, json?, fn actor ->
          case create_account_result(workspace, email, password, roles, actor) do
            {:ok, principal} ->
              # The report is a separate step, so that the bootstrap path can
              # spend the token **before** it says the account exists.
              {:ok, fn -> report_account(workspace, principal, email, json?) end}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      {:error, reason} ->
        auth_error(reason, json?)
    end
  end

  defp account("set-password", opts, json?) do
    workspace = workspace(opts)
    email = opts[:email]
    password = secret(opts[:password], "VERITAS_ACCOUNT_PASSWORD")

    cond do
      is_nil(email) ->
        usage_error("account set-password needs --email", json?)

      is_nil(password) ->
        usage_error(
          "account set-password needs --password, or VERITAS_ACCOUNT_PASSWORD in the environment",
          json?
        )

      true ->
        # A reset is never a bootstrap act: there is always an
        # administrator to ask.
        operator_authority(workspace, opts[:as], json?, fn actor ->
          case set_password_result(workspace, email, password, actor) do
            {:ok, account_id} ->
              {:ok, fn -> report_password_reset(workspace, email, account_id, json?) end}

            {:error, reason} ->
              {:error, reason}
          end
        end)
    end
  end

  defp account("bootstrap-token", opts, json?) do
    workspace = workspace(opts)
    path = opts[:file] || Veritas.Core.BootstrapToken.secret_path(workspace)

    case Veritas.Core.BootstrapToken.issue(workspace, path: path) do
      {:ok, path} ->
        copied = copy_to_clipboard(opts, path, workspace)

        if json? do
          emit_json(%{
            bootstrap_token: %{workspace: workspace, path: path, copied: copied == :ok}
          })
        else
          Mix.shell().info("bootstrap token for #{workspace} written to #{path} (mode 0600).")
          Mix.shell().info("It is not printed. Move it into wherever you keep secrets;")

          if copied == :ok do
            Mix.shell().info(
              "it is also on the clipboard, and other processes can read the clipboard."
            )
          end

          if copied == {:error, :clipboard_unavailable} do
            Mix.shell().info("clipboard unavailable; the token remains available in the file.")
          end

          Mix.shell().info("and the file is spent when the token is used.")
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        store_error(reason, json?)
    end
  end

  defp account(_subcommand, _opts, _json?), do: usage()

  # The authority for an account command.
  defp with_authority(workspace, opts, json?, fun) do
    if opts[:as] do
      operator_authority(workspace, opts[:as], json?, fun)
    else
      bootstrap_authority(workspace, opts, json?, fun)
    end
  end

  # The operator path: the caller acts as an account, and the Policy decides.
  defp operator_authority(workspace, operator, json?, fun) do
    principal = operator_principal(workspace, operator, json?)

    case Policy.authorize(principal, "account:administrate", %{workspace: workspace}) do
      :allow ->
        case fun.(principal.id) do
          {:ok, report} ->
            report.()
            exit({:shutdown, @exit_ok})

          {:error, reason} ->
            auth_error(reason, json?)
        end

      {:deny, reason} ->
        refuse(reason, json?, %{code: :not_authorised})
    end
  end

  defp operator_principal(workspace, operator, json?) do
    password = secret(nil, "VERITAS_OPERATOR_PASSWORD")

    cond do
      is_nil(operator) ->
        usage_error(
          "this command needs --as EMAIL or VERITAS_OPERATOR_EMAIL: the account the operator acts as",
          json?
        )

      is_nil(password) ->
        usage_error("set the operator's password in VERITAS_OPERATOR_PASSWORD", json?)

      true ->
        case Veritas.Authn.authenticate(workspace, %{email: operator, password: password}) do
          {:ok, principal} ->
            principal

          {:error, _reason} ->
            refuse("the operator's credentials were refused", json?, %{code: :not_authorised})
        end
    end
  end

  # The bootstrap path: a Workspace with no accounts, and the one-time token.
  #
  # The token is never taken from the command line. A command line is
  # readable by every process on the machine, so the token comes from the
  # environment, from standard input, from a file, or from a masked prompt.
  defp bootstrap_authority(workspace, opts, json?, fun) do
    case bootstrap_token(workspace, opts) do
      {:ok, token} ->
        # The token is checked before anything else, because it is bound to
        # this Workspace: a token issued for another one finds nothing here.
        #
        # It is **claimed**, not spent. The claim is an exclusive create, so
        # two bootstraps at the same time cannot both go on to create an
        # account from one token. The token is spent once the account
        # exists, and released when the account does not: a refused email or
        # password must not burn a one-time credential.
        token_opts = [path: opts[:file] || opts[:bootstrap_token_file]]

        case Veritas.Core.BootstrapToken.claim(workspace, token, token_opts) do
          {:ok, claim} ->
            case accounts?(workspace) do
              {:ok, false} ->
                case fun.("bootstrap") do
                  {:ok, report} ->
                    # The account exists, so the token is spent and the
                    # delivery copy is emptied with it.
                    Veritas.Core.BootstrapToken.spend(claim, token_opts)
                    report.()
                    exit({:shutdown, @exit_ok})

                  {:error, reason} ->
                    # The account was refused. The token was not used, so it
                    # is not spent.
                    Veritas.Core.BootstrapToken.release(claim, token_opts)
                    auth_error(reason, json?)
                end

              {:ok, true} ->
                Veritas.Core.BootstrapToken.release(claim, token_opts)

                refuse(
                  "the workspace already has accounts; use --as EMAIL or VERITAS_OPERATOR_EMAIL",
                  json?,
                  %{code: :not_authorised}
                )

              {:error, reason} ->
                Veritas.Core.BootstrapToken.release(claim, token_opts)
                store_error(reason, json?)
            end

          {:error, _reason} ->
            refuse("the bootstrap token was refused", json?, %{code: :not_authorised})
        end

      {:error, reason} ->
        usage_error(token_source_message(reason), json?)
    end
  end

  # Where the bootstrap token comes from, in order.
  #
  #   1. the environment — safe from the process list, and the one a
  #      pipeline uses;
  #   2. standard input, when the caller says it is there;
  #   3. a file the caller names;
  #   4. the file the token was written to;
  #   5. a masked prompt, with the terminal's echo genuinely switched off.
  defp bootstrap_token(workspace, opts) do
    cond do
      token = present(System.get_env(Veritas.Core.BootstrapToken.token_env_var())) ->
        {:ok, token}

      opts[:bootstrap_token_stdin] == true ->
        read_token_from_stdin()

      opts[:bootstrap_token_file] ->
        Veritas.Core.BootstrapToken.read_token(opts[:bootstrap_token_file])

      true ->
        case Veritas.Core.BootstrapToken.read_token(
               Veritas.Core.BootstrapToken.secret_path(workspace)
             ) do
          {:ok, token} -> {:ok, token}
          {:error, _reason} -> prompt_for_token()
        end
    end
  end

  defp read_token_from_stdin do
    # The echo is switched off where the terminal allows it, so a token typed
    # at a terminal does not appear on the screen. A pipe has no echo to
    # switch off, and the read still works. The seam is
    # `Veritas.Dev.Terminal`, so the read does not need a POSIX shell.
    case Veritas.Dev.Terminal.read_line() do
      {:ok, line} -> {:ok, line}
      {:error, :eof} -> {:error, :no_token_on_stdin}
      {:error, :no_terminal} -> {:error, :no_token_on_stdin}
    end
  end

  # A masked prompt: the terminal's echo is switched off for the read, so the
  # token does not appear on the screen. If the terminal will not do it, the
  # prompt is refused — a masked-looking input that still echoes is worse
  # than no prompt, because it looks safe.
  defp prompt_for_token do
    case Veritas.Dev.Terminal.masked_read("bootstrap token: ") do
      {:ok, line} ->
        {:ok, line}

      {:error, :eof} ->
        {:error, :no_token_on_stdin}

      {:error, :no_terminal} ->
        {:error, :no_terminal_to_prompt_on}
    end
  end

  defp token_source_message(:no_terminal_to_prompt_on) do
    "there is no terminal to prompt on; put the token in #{Veritas.Core.BootstrapToken.token_env_var()}, " <>
      "or use --bootstrap-token-stdin, or --bootstrap-token-file"
  end

  defp token_source_message(:no_token_on_stdin) do
    "no token on standard input; put the token in #{Veritas.Core.BootstrapToken.token_env_var()}, " <>
      "or use --bootstrap-token-file"
  end

  defp token_source_message(:no_token_for_workspace) do
    "that file holds no token for this workspace; run `mix veritas.cli account bootstrap-token` first"
  end

  defp token_source_message(_reason) do
    "the bootstrap token could not be read; put it in #{Veritas.Core.BootstrapToken.token_env_var()}, " <>
      "or use --bootstrap-token-stdin, or --bootstrap-token-file"
  end

  # The clipboard is a convenience, not a channel of record: every process
  # the user runs can read it.
  defp copy_to_clipboard(opts, path, _workspace) do
    if opts[:copy] == true do
      with {:ok, token} <- Veritas.Core.BootstrapToken.read_token(path),
           :ok <- Veritas.Dev.Clipboard.copy(token) do
        :ok
      else
        _ -> {:error, :clipboard_unavailable}
      end
    else
      :not_requested
    end
  end

  # Creates the account, and says what happened.
  #
  # The creation and the report are separate steps, because the bootstrap
  # path has to spend the token **between** them: the token is spent when
  # the account exists, not when the command says so.
  defp create_account_result(workspace, email, password, roles, actor) do
    attrs = %{
      email: email,
      display_name: email,
      roles: roles,
      password: password
    }

    Veritas.Authn.create_account(
      workspace,
      attrs,
      actor_id: actor,
      reason: "the operator created the account"
    )
  end

  defp report_account(workspace, principal, email, json?) do
    if json? do
      emit_json(%{
        account: %{
          id: principal.id,
          email: email,
          workspace: workspace,
          roles: Principal.role_strings(principal)
        }
      })
    else
      Mix.shell().info(
        "created #{email} in #{workspace} with #{Enum.join(Principal.role_strings(principal), ", ")}"
      )
    end

    :ok
  end

  defp set_password_result(workspace, email, password, actor) do
    case Veritas.Authn.account_id(workspace, email) do
      {:ok, account_id} ->
        case Veritas.Authn.set_password(
               workspace,
               account_id,
               password,
               actor_id: actor,
               reason: "the operator reset the password"
             ) do
          {:ok, _principal} -> {:ok, account_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp report_password_reset(workspace, email, account_id, json?) do
    if json? do
      emit_json(%{
        account: %{
          id: account_id,
          email: email,
          workspace: workspace,
          password_changed: true
        }
      })
    else
      Mix.shell().info("reset the password for #{email} in #{workspace}")
    end

    :ok
  end

  # The roles the Policy knows, and only those. A name that is not in the
  # `docs/02` set is refused here rather than stored and ignored later.
  defp role_names(names) do
    Enum.reduce_while(List.wrap(names), {:ok, []}, fn name, {:ok, acc} ->
      case Principal.known_role(name) do
        nil -> {:halt, {:error, {:unknown_role, name}}}
        role -> {:cont, {:ok, [Principal.role_name(role) | acc]}}
      end
    end)
    |> case do
      {:ok, roles} -> {:ok, Enum.reverse(roles)}
      error -> error
    end
  end

  defp accounts?(workspace) do
    case Store.transaction(workspace, fn tx -> Store.list(tx, :user, %{limit: 1}) end) do
      {:ok, rows} -> {:ok, rows != []}
      {:error, reason} -> {:error, reason}
    end
  end

  # A secret may be given on the command line or in the environment. The
  # environment is the better of the two: a command line is in the shell's
  # history.
  defp secret(nil, variable), do: present(System.get_env(variable))
  defp secret(value, _variable), do: present(value)

  defp present(""), do: nil
  defp present(value), do: value

  # A refusal from the authentication port, as a message and an exit code.
  defp auth_error(%Error{} = reason, json?), do: store_error(reason, json?)

  defp auth_error(reason, json?) do
    {message, code} =
      case reason do
        {:unknown_role, name} ->
          {"the role #{inspect(name)} is not in the docs/02 role set", :unknown_role}

        other ->
          {auth_message(other), auth_code(other)}
      end

    refuse(message, json?, %{code: code})
  end

  defp auth_message(:password_breached), do: "the password is on the breached-password list"
  defp auth_message(:account_exists), do: "an account with that email already exists"
  defp auth_message(:invalid_email), do: "the email address is not usable"
  defp auth_message(:password_required), do: "a password is required"
  defp auth_message(:breach_list_unavailable), do: "the breached-password list could not be read"
  defp auth_message(:account_missing), do: "no such account"
  defp auth_message(:invalid_credentials), do: "the credentials were refused"
  defp auth_message(:unsupported), do: "the installed Adapter does not support local accounts"
  defp auth_message(other), do: Error.message(other) || "the domain refused the operation"

  defp auth_code(:password_breached), do: :password_breached
  defp auth_code(:account_exists), do: :account_exists
  defp auth_code(:account_missing), do: :account_missing
  defp auth_code(other), do: error_code(other)

  # ── the CMDB ──────────────────────────────────────────────────────────────

  # The CMDB's commands. They call `Veritas.Core.CI`, the same module the
  # GraphQL and the LiveViews call (INV-8): one implementation, many
  # surfaces.
  defp ci("list", opts, json?) do
    filters =
      []
      |> put_opt(:ci_type, opts[:type])
      |> put_opt(:lifecycle_state, opts[:lifecycle])
      |> put_opt(:criticality, opts[:criticality])
      |> put_opt(:limit, opts[:limit])

    case CI.list(workspace(opts), filters) do
      {:ok, rows} ->
        if json? do
          emit_json(%{cis: rows})
        else
          Mix.shell().info(
            "ID                    TYPE         LIFECYCLE       CRITICALITY   NAME"
          )

          Enum.each(rows, fn row ->
            Mix.shell().info(
              String.pad_trailing(bare_id(row["id"]), 21) <>
                String.pad_trailing(to_string(row["ci_type"]), 13) <>
                String.pad_trailing(to_string(row["lifecycle_state"]), 16) <>
                String.pad_trailing(to_string(row["criticality"]), 13) <>
                to_string(row["name"])
            )
          end)
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        ci_error(reason, json?)
    end
  end

  defp ci("show", opts, json?) do
    with {:ok, ci} <- resolve_ci(workspace(opts), opts[:id] || "", json?) do
      depth = opts[:depth] || 2

      relations = CI.relations(workspace(opts), ci["id"], :in, depth)
      dependencies = CI.relations(workspace(opts), ci["id"], :out, depth)
      impact = CI.impact(workspace(opts), ci["id"], depth)

      if json? do
        emit_json(%{
          ci: ci,
          dependents: node_names(relations),
          dependencies: node_names(dependencies),
          impact: impact
        })
      else
        Mix.shell().info(Jason.encode!(ci, pretty: true))
        Mix.shell().info("\ndependents (what depends on it):")

        Enum.each(node_names(relations), fn name -> Mix.shell().info("  #{name}") end)

        Mix.shell().info("dependencies (what it depends on):")

        Enum.each(node_names(dependencies), fn name -> Mix.shell().info("  #{name}") end)

        Mix.shell().info("\nimpact:")

        case impact do
          {:ok, impact} ->
            Mix.shell().info(Jason.encode!(impact, pretty: true))

          {:error, reason} ->
            Mix.shell().error("store error: #{Error.message(reason) || "the datastore failed"}")
        end
      end

      exit({:shutdown, @exit_ok})
    end
  end

  defp ci("create", opts, json?) do
    attrs = %{
      "ci_type" => opts[:type],
      "name" => opts[:name],
      "lifecycle_state" => opts[:lifecycle],
      "criticality" => opts[:criticality],
      "owner" => opts[:owner],
      "attributes" => attributes(opts),
      "reason" => opts[:reason]
    }

    case CI.create(workspace(opts), attrs) do
      {:ok, ci} ->
        if json? do
          emit_json(%{ci: ci})
        else
          Mix.shell().info("created #{bare_id(ci["id"])} (#{ci["ci_type"]}) #{ci["name"]}")
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        ci_error(reason, json?)
    end
  end

  defp ci("relate", opts, json?) do
    with {:ok, from} <- resolve_ci(workspace(opts), opts[:from] || "", json?),
         {:ok, to} <- resolve_ci(workspace(opts), opts[:to] || "", json?) do
      attrs = attributes(opts) |> Map.put("reason", opts[:reason] || "related through the CMDB")

      case CI.relate(workspace(opts), from["id"], opts[:kind] || "", to["id"], attrs) do
        {:ok, edge} ->
          if json? do
            emit_json(%{relation: edge})
          else
            Mix.shell().info(
              "related #{bare_id(from["id"])} #{edge["kind"]} #{bare_id(to["id"])}"
            )
          end

          exit({:shutdown, @exit_ok})

        {:error, reason} ->
          ci_error(reason, json?)
      end
    end
  end

  defp ci("seed", opts, json?) do
    case seed(workspace(opts)) do
      {:ok, report} ->
        if json? do
          emit_json(report)
        else
          Mix.shell().info("seeded the CMDB of #{workspace(opts)}:")

          Enum.each(report[:cis], fn ci ->
            Mix.shell().info("  #{bare_id(ci["id"])}  #{ci["ci_type"]}  #{ci["name"]}")
          end)

          Enum.each(report[:relations], fn relation ->
            Mix.shell().info("  #{relation["from"]} #{relation["kind"]} #{relation["to"]}")
          end)
        end

        exit({:shutdown, @exit_ok})

      {:error, reason} ->
        ci_error(reason, json?)
    end
  end

  defp ci(_subcommand, _opts, _json?), do: usage()

  # ── the demonstration seed ─────────────────────────────────────────────────

  # A small, realistic CMDB, so the owner can see a populated one.
  #
  # This is a demonstration aid and it says so: it is not part of the domain,
  # it registers the CI types it needs (the type registry is data — ADR-009),
  # and it creates the CIs only when the Workspace does not already hold them,
  # so running it twice does not double the CMDB.
  #
  # The shape it draws: two web servers on one database, an application that
  # depends on one of them, and the tier-one service that depends on the
  # application and provides it. A service that depends on the application is
  # what the impact query answers with.
  @seed_types [
    %{
      "id" => "server",
      "name" => "server",
      "plural" => "servers",
      "required" => ["region"],
      "schema" => %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "enum" => ["eu-west-1", "us-east-1"]},
          "cpu_cores" => %{"type" => "integer", "minimum" => 1},
          "role" => %{"type" => "string"}
        }
      }
    },
    %{
      "id" => "database",
      "name" => "database",
      "plural" => "databases",
      "required" => [],
      "schema" => %{
        "type" => "object",
        "properties" => %{
          "engine" => %{"type" => "string"},
          "version" => %{"type" => "string"}
        }
      }
    },
    %{
      "id" => "application",
      "name" => "application",
      "plural" => "applications",
      "required" => [],
      "schema" => %{
        "type" => "object",
        "properties" => %{
          "vendor" => %{"type" => "string"},
          "version" => %{"type" => "string"},
          "environment" => %{
            "type" => "string",
            "enum" => ["development", "staging", "production"]
          }
        }
      }
    },
    %{
      "id" => "service",
      "name" => "service",
      "plural" => "services",
      "required" => ["tier"],
      "schema" => %{
        "type" => "object",
        "properties" => %{
          "tier" => %{"type" => "string", "enum" => ["tier1", "tier2", "tier3"]},
          "owner_org" => %{"type" => "string"}
        }
      }
    }
  ]

  @seed_kinds [
    %{"id" => "runs_on", "from_table" => "ci", "to_table" => "ci", "inverse" => "hosted_on"},
    %{"id" => "provides", "from_table" => "ci", "to_table" => "ci", "inverse" => "provided_by"}
  ]

  @seed_cis [
    {"db-01", "database", %{"engine" => "postgres", "version" => "16.2"}},
    {"web-01", "server", %{"region" => "eu-west-1", "cpu_cores" => 8, "role" => "web"}},
    {"web-02", "server", %{"region" => "eu-west-1", "cpu_cores" => 4, "role" => "web"}},
    {"app-01", "application",
     %{"vendor" => "in-house", "version" => "4.2.0", "environment" => "production"}},
    {"svc-checkout", "service", %{"tier" => "tier1", "owner_org" => "commerce"}}
  ]

  @seed_relations [
    {"web-01", "runs_on", "db-01"},
    {"web-02", "runs_on", "db-01"},
    {"app-01", "depends_on", "web-01"},
    {"svc-checkout", "depends_on", "app-01"},
    {"svc-checkout", "provides", "app-01"}
  ]

  defp seed(workspace) do
    with :ok <- seed_types(workspace),
         :ok <- seed_kinds(workspace),
         {:ok, cis} <- seed_cis(workspace),
         {:ok, relations} <- seed_relations(workspace, cis) do
      {:ok, %{cis: cis, relations: relations}}
    end
  end

  defp seed_types(workspace) do
    Enum.reduce_while(@seed_types, :ok, fn type, _acc ->
      case CI.register_type(workspace, type) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_kinds(workspace) do
    Enum.reduce_while(@seed_kinds, :ok, fn kind, _acc ->
      case CI.register_relation_kind(workspace, kind) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_cis(workspace) do
    Enum.reduce_while(@seed_cis, {:ok, []}, fn {name, type, attributes}, {:ok, acc} ->
      case CI.list(workspace, ci_type: type, limit: 500) do
        {:ok, rows} ->
          case Enum.find(rows, &(&1["name"] == name)) do
            nil ->
              case CI.create(workspace, %{
                     "ci_type" => type,
                     "name" => name,
                     "attributes" => attributes
                   }) do
                {:ok, ci} -> {:cont, {:ok, acc ++ [ci]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            ci ->
              {:cont, {:ok, acc ++ [ci]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp seed_relations(workspace, cis) do
    by_name = Map.new(cis, &{&1["name"], &1["id"]})

    Enum.reduce_while(@seed_relations, {:ok, []}, fn {from, kind, to}, {:ok, acc} ->
      with true <- Map.has_key?(by_name, from) and Map.has_key?(by_name, to),
           {:ok, edge} <- CI.relate(workspace, by_name[from], kind, by_name[to]) do
        {:cont, {:ok, acc ++ [edge]}}
      else
        false -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A CI may be named by its id or by its name: the CLI is a surface people
  # use, and a name is what they know. A name is not a record id, so the id
  # lookup is tried first and the name lookup answers when it does not.
  defp resolve_ci(workspace, reference, json?) do
    if reference == "" do
      refuse("a CI needs an id or a name", json?, %{})
    else
      case CI.get(workspace, reference) do
        {:ok, nil} -> resolve_by_name(workspace, reference, json?)
        {:ok, ci} -> {:ok, ci}
        {:error, _reason} -> resolve_by_name(workspace, reference, json?)
      end
    end
  end

  defp resolve_by_name(workspace, name, json?) do
    case CI.list(workspace, limit: 500) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1["name"] == name)) do
          [ci] ->
            {:ok, ci}

          [] ->
            refuse("no configuration item named #{inspect(name)}", json?, %{name: name})

          many ->
            refuse(
              "#{length(many)} configuration items are named #{inspect(name)}; use the id",
              json?,
              %{name: name}
            )
        end

      {:error, reason} ->
        ci_error(reason, json?)
    end
  end

  defp node_names({:ok, %{nodes: nodes}}), do: Enum.map(nodes, &to_string(&1["name"]))
  defp node_names(_other), do: []

  # The `--attr name=value` options, as an attribute map.
  defp attributes(opts) do
    opts
    |> Keyword.get_values(:attr)
    |> List.flatten()
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.reduce(%{}, fn
      [name, value], acc -> Map.put(acc, name, attribute_value(value))
      [name], acc -> Map.put(acc, name, true)
    end)
  end

  # The shell gives strings. The obvious scalars are read as the scalars they
  # look like, so an attribute the type's schema calls an integer can be
  # written from the command line.
  defp attribute_value(value) do
    case value do
      "true" -> true
      "false" -> false
      _ -> scalar(value)
    end
  end

  defp scalar(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  # A domain refusal is a message; a store failure is the store's error.
  # Neither carries the engine's internals into the JSON.
  defp ci_error(reason, json?) when is_binary(reason) do
    refuse(reason, json?, %{code: :refused})
  end

  defp ci_error(reason, json?), do: store_error(reason, json?)

  # The diagnostic surface: what the system is, and whether it is healthy.
  # Reports the datastore (which Adapter is installed, what it can do, whether
  # it answers), the schema version, the Audit Log chain, and the cluster.
  defp doctor(opts, json?) do
    report = Veritas.Core.Doctor.report(workspace(opts))

    if json? do
      emit_json(%{doctor: report})
    else
      Mix.shell().info(Veritas.Core.Doctor.format(report))
    end

    if report[:healthy], do: exit({:shutdown, @exit_ok}), else: exit({:shutdown, @exit_unhealthy})
  end

  # ── output helpers ────────────────────────────────────────────────────────

  defp emit_json(payload) do
    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end

  defp refuse(message, json?, details) do
    if json? do
      emit_json(%{error: Map.put(details, :message, message)})
    else
      Mix.shell().error("refused: #{message}")
    end

    exit({:shutdown, @exit_refused})
  end

  defp public_failure(%Error{} = reason, json?), do: store_error(reason, json?)
  defp public_failure(reason, json?) do
    safe = Error.public(reason)
    refuse(safe.message, json?, Map.delete(safe, :message))
  end

  defp store_error(reason, json?) do
    safe = Error.public(reason)

    if json? do
      emit_json(%{error: safe})
    else
      Mix.shell().error("store error: #{safe.message}")
    end

    exit({:shutdown, @exit_store})
  end

  # The machine-readable code of a failure, and nothing else.
  #
  # The inspected reason is the datastore's own error structure — its body,
  # its query, its internals. A CLI answers the operator who asked a question;
  # it does not echo the engine's internals back to whatever is reading the
  # output, which is usually a script.
  defp error_code(%Error{code: code}), do: code
  defp error_code(reason) when is_atom(reason), do: reason
  defp error_code({:shutdown, code}) when is_atom(code), do: code
  defp error_code(_reason), do: "store_error"

  # A record id may arrive with its table prefix; the CLI shows the bare id.
  defp bare_id(id), do: id |> to_string() |> String.split(":") |> List.last()

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp usage do
    Mix.shell().info("""
    veritas.cli — the command-line surface

      tickets      --workspace W [--type T] [--state S]
      show         --workspace W --id ID
      open         --workspace W --type T --title TITLE --requester USER
      transition   --workspace W --id ID --to-state STATE [--as EMAIL]
      update       --workspace W --id ID [--title TITLE] [--description TEXT] [--actor USER]
      impact       --workspace W --ci CI [--depth N]
      ci ...       list | show | create | relate | seed
      account ...  bootstrap-token | create | set-password
      workflow ... template | list | show | save | publish | start | run | complete | draft | generate
      incident show --workspace W --id ID --as EMAIL
      incident update --id ID --file FACTS.json --domain-revision N|null [--revision RUN]
      incident-policy show|validate|save|publish --workspace W --as EMAIL
        validate/save: --file POLICY.json; save/publish: --policy-revision N|null
        publish: --approve; optional --policy-version ID|null checks active version
      Incident mutations: --domain-file FACTS.json --domain-revision N|null
        --revision is workflow-only; omitted preconditions are not explicit null.
      audit verify --workspace W
      migrate
      doctor       [--workspace W]

    Operator identity:

      Set VERITAS_OPERATOR_EMAIL to omit --as on transitions, workflows and account
      commands. An explicit --as EMAIL takes precedence; a blank environment
      value is ignored. Set the operator's password in VERITAS_OPERATOR_PASSWORD.

    Editable ticket workflows:

      workflow template [--type incident]
          Print an editable workflow JSON definition; save it to workflow.json.
      workflow save --file workflow.json [--id ID --revision N]
          Save a draft. Existing drafts require their current revision.
      workflow publish --id ID --revision N
          Publish the saved draft after validating every lifecycle path.
      workflow start --id ID --file intake.json
          Create a real ticket. JSON contains title, description and an answers object.
      workflow run --id TICKET
          Read the ticket's recorded workflow, current step, answers and AI outputs.
      workflow draft --id TICKET [--model MODEL]
          Request an AI proposal for the current step; it remains unapproved.
      workflow complete --id TICKET --revision N [--file answers.json] [--next STEP] [--approve]
          Record an answers JSON object and choose a configured branch. AI and
          approval steps require explicit human review with --approve.
      workflow generate --prompt TEXT [--type incident] [--model MODEL]
          Ask AI for a draft definition; inspect and save it before publishing.
      workflow list | show --id ID
          List workflows or read one workflow, including its saved revision.

      Use --workspace W on every command when working outside the default Workspace.

    The accounts:

      account bootstrap-token --workspace W [--file PATH] [--copy]
          Issue the one-time bootstrap token for a Workspace that has no
          accounts yet. The token is written to a file at mode 0600 and the
          path is printed — the token itself is not.

      account create --workspace W --email E --password P --role R [--role R]
          Create a local account. The first account in a Workspace needs a
          bootstrap token; every other account needs an operator identity
          (--as EMAIL or VERITAS_OPERATOR_EMAIL) and the operator's password
          in VERITAS_OPERATOR_PASSWORD.

      account set-password --workspace W --email E --password P [--as EMAIL]
          Reset a password. It needs an operator identity and password:
          a reset is never a bootstrap act.

      The password may be given in VERITAS_ACCOUNT_PASSWORD instead of
      --password, so that it need not appear in a shell's history. It is
      never echoed.

      A bootstrap token is never taken on the command line, because a command
      line is readable by every process on the machine. It is read from
      VERITAS_BOOTSTRAP_TOKEN, from standard input (--bootstrap-token-stdin),
      from a file (--bootstrap-token-file), or from a masked prompt.

    The roles — the docs/02 set; the corpus's own spelling is accepted too:
    #{role_help()}

    Add --json to any command for machine-readable output.

    Exit codes: 0 ok, 1 usage, 2 refused, 3 store error, 4 audit chain broken,
    5 doctor found a fault.
    """)

    exit({:shutdown, @exit_usage})
  end

  # The roles the Policy knows, named the way the command line writes them.
  defp role_help do
    Principal.role_names()
    |> Enum.sort_by(fn {role, _} -> Atom.to_string(role) end)
    |> Enum.map_join("\n", fn {role, spelled} -> "  #{Atom.to_string(role)} (#{spelled})" end)
  end

  # A usage error is not a refusal: the command was wrong, not the domain.
  defp usage_error(message, json?) do
    if json? do
      emit_json(%{error: %{code: :usage, message: message}})
    else
      Mix.shell().error("usage: #{message}")
    end

    exit({:shutdown, @exit_usage})
  end
end
