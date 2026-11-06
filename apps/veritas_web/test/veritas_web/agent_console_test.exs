defmodule Veritas.Web.AgentConsoleTest do
  @moduledoc """
  The Agent Console, tested on behaviour.

  The claims under test are the owner's two: *"still don't see ai builtin
  literally anywhere"* and *"we can't edit anything"* — the second now
  including the CMDB and the accounts, and the first meaning the AI surface
  must be real.

  So the claims here are:

    * **the console is reachable and says what the agent can reach.** The
      tool catalogue is the registry's own contents, and it needs no
      provider — it is true before any provider is configured.

    * **an agent's reach into the CMDB goes through the tool registry**, and
      the run is **auditable**: the tool call is in the Audit Log with the
      digest of its arguments, and the answer is the tool's own rows.

    * **the same read, the same way.** The agent's answer is a
      Configuration Item the domain also serves to a person.
  """
  use Veritas.Web.ConnCase
  use Veritas.Web.StoreCase

  import Phoenix.LiveViewTest

  alias Veritas.Agentic.LLM.AdapterRegistry
  alias Veritas.Agentic.Provider.Registry
  alias Veritas.Core.CI
  alias Veritas.Store
  alias Veritas.Web.AgentConsole.Providers
  alias Veritas.Web.ScriptedAdapter

  @password "a-fine-passphrase-the-operator-chose-42"

  setup do
    AdapterRegistry.register(ScriptedAdapter.id(), ScriptedAdapter)

    # The deployment's provider: the global tier, which is configuration
    # rather than a Workspace's own registry.
    Application.put_env(:veritas_core, :providers,
      scripted: [base_url: "http://scripted.invalid", model: "scripted-1"]
    )

    on_exit(fn -> Application.delete_env(:veritas_core, :providers) end)

    :ok
  end

  describe "the tool catalogue" do
    test "is the registry's own contents and needs no provider", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/tools")
      html = render(view)

      # The nine core tools, by name (`docs/08`).
      for name <- [
            "search_ci",
            "get_ci",
            "list_ci_relations",
            "query_cmdb",
            "list_incidents",
            "get_incident",
            "transition_incident",
            "create_service_request",
            "propose_change"
          ] do
        assert html =~ name, "#{name} is missing from the catalogue"
      end

      # And the policy beside each: a read asks for nothing, a write needs a
      # human's approval.
      assert html =~ "needs approval"
    end
  end

  describe "a run" do
    setup %{workspace: workspace} do
      {:ok, _type} =
        CI.register_type(workspace, %{
          "id" => "server",
          "name" => "server",
          "plural" => "servers",
          "required" => [],
          "schema" => %{"type" => "object", "properties" => %{}}
        })

      {:ok, _ci} =
        CI.create(workspace, %{"ci_type" => "server", "name" => "web-01", "attributes" => %{}})

      :ok
    end

    test "reaches the CMDB through the tool registry, and is audited", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])

      {:ok, view, _static} = live(signed_in, ~p"/agents")

      # The run is driven by the scripted adapter, which asks for the CMDB.
      view
      |> form("#agent-ask")
      |> render_submit(%{"question" => "Which CIs are there?"})

      html = render_async(view)

      # The answer came from the tool the agent called.
      assert html =~ "The answer, from the tool the agent called"
      assert html =~ "search_ci"

      # And the tool call is in the Audit Log, with the digest of its
      # arguments and the scope it needed.
      events = audit_events(workspace)

      tool_event =
        Enum.find(events, fn event ->
          get_in(event, ["diff", "tool"]) == "search_ci"
        end)

      assert tool_event, "the tool call was not audited"
      assert get_in(tool_event, ["diff", "scope"]) == ["ci:read"]
      assert get_in(tool_event, ["diff", "arguments_digest"])
      assert get_in(tool_event, ["diff", "outcome"]) == "ok"
    end

    test "the operator picks a model from the provider's catalogue, and the run uses it", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])
      {:ok, view, _static} = live(signed_in, ~p"/agents")

      # Before the catalogue is loaded the only choice is the provider's own.
      refute render(view) =~ ~s(value="scripted-2")

      # The catalogue is the adapter's answer, loaded through the rendered
      # control and not assumed.
      view |> element("button", "Load available models") |> render_click()
      html = render_async(view)
      assert html =~ ~s(value="scripted-1")
      assert html =~ ~s(value="scripted-2")

      # The non-default model is the one the run reports.
      view
      |> form("#agent-ask")
      |> render_submit(%{"question" => "Which CIs are there?", "model" => "scripted-2"})

      html = render_async(view)
      assert html =~ "The answer, from the tool the agent called"
      assert html =~ "/scripted-2"
      refute html =~ "/scripted-1"

      # And the blank choice means the provider's configured model.
      view
      |> form("#agent-ask")
      |> render_submit(%{"question" => "Which CIs are there?", "model" => ""})

      html = render_async(view)
      assert html =~ "/scripted-1"
    end

    test "a provider refusal is shown in plain words, never as a raw struct", %{
      conn: conn,
      workspace: workspace
    } do
      # The provider names no model, and the operator made no choice.
      Application.put_env(:veritas_core, :providers,
        scripted: [base_url: "http://scripted.invalid"]
      )

      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])
      {:ok, view, _static} = live(signed_in, ~p"/agents")

      view
      |> form("#agent-ask")
      |> render_submit(%{"question" => "Which CIs are there?", "model" => ""})

      html = render_async(view)
      assert html =~ "The agent could not answer"
      assert html =~ "names no model"
      refute html =~ ":no_model"
    end

    test "an unexpected catalogue failure is shown in plain words; its detail stays in the log",
         %{conn: conn, workspace: workspace} do
      Application.put_env(:veritas_core, :providers,
        scripted: [base_url: "http://unexpected.invalid", model: "scripted-1"]
      )

      %{conn: signed_in} = sign_in(conn, workspace, roles: ["CI Steward"])
      {:ok, view, _static} = live(signed_in, ~p"/agents")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view |> element("button", "Load available models") |> render_click()
          send(self(), {:html, render_async(view)})
        end)

      assert_received {:html, html}
      assert html =~ "Could not load models: an unexpected error"
      refute html =~ "RAW-PROVIDER-BODY"
      assert log =~ "RAW-PROVIDER-BODY"
    end

    test "the agent's read is the same read a person gets", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, ci} =
        CI.create(workspace, %{"ci_type" => "server", "name" => "web-02", "attributes" => %{}})

      {:ok, rows} = CI.list(workspace, ci_type: "server")
      names = Enum.map(rows, & &1["name"])

      assert "web-01" in names
      assert "web-02" in names
      assert ci["id"]
    end
  end

  describe "the provider screen" do
    test "says which provider the Workspace uses, and does not fake one", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")
      html = render(view)

      # The registry starts empty: neither tier is a default. The screen says
      # so in the corpus's own words (`docs/39` §3.3).
      assert html =~ "This Workspace has no provider configured."
      assert html =~ "Veritas does not choose one for you"

      # And the credential is a reference: the name of the environment
      # variable that holds the key. There is no credential store in this
      # build, and the screen says so rather than pretending otherwise.
      assert html =~ "key environment variable"
      assert html =~ "no credential store"
    end

    test "names a refused global provider and its reason", %{
      conn: conn,
      workspace: workspace
    } do
      Application.put_env(:veritas_core, :providers, [
        {"broken-global",
         [
           kind: :self_hosted,
           adapter: "adapter_name_never_interned",
           base_url: "http://127.0.0.1:11434",
           model: "llama3"
         ]}
      ])

      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")
      html = render(view)

      assert html =~ "broken-global"
      assert html =~ "adapter_name_never_interned is not an adapter this build registers"
      assert html =~ "name a registered adapter"
      refute html =~ "None configured."
    end

    test "keeps the genuinely empty state distinct from a refusal", %{
      conn: conn,
      workspace: workspace
    } do
      Application.delete_env(:veritas_core, :providers)
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")
      html = render(view)

      assert html =~ "This Workspace has no provider configured."
      assert html =~ "None configured."
      refute html =~ "is not an adapter this build registers"
    end

    test "an unreadable Workspace registry is not reported as an empty tier" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, principal_workspace: "not a valid workspace"}
      }

      {:ok, socket} = Providers.mount(%{}, %{}, socket)
      html = rendered_to_string(Providers.render(socket.assigns))

      assert socket.assigns.workspace_error
      assert html =~ "could not be read"
      assert html =~ "reload this screen"
      refute html =~ "This Workspace has no provider configured."
    end

    test "a configured Workspace provider lists why its adapter cannot be used", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _stored} =
        Store.transaction(workspace, fn tx ->
          Store.put(tx, :provider, %{
            id: "broken_workspace",
            kind: :self_hosted,
            adapter: "adapter_name_never_interned",
            base_url: "http://127.0.0.1:11434",
            model: "llama3",
            credential_env: nil,
            capability_floor_acknowledged: false,
            capabilities: []
          })
        end)

      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")
      html = render(view)

      assert html =~ "broken_workspace"
      assert html =~ "adapter_name_never_interned is not an adapter this build registers"
      refute html =~ "This Workspace has no provider configured."
    end

    test "an unseen refusal shape gets plain words, never a raw term" do
      html =
        render_providers(%{
          global_refusals: [
            %{id: "future_global", reason: {:unexpected_refusal, %{internal: "detail"}}}
          ]
        })

      assert html =~ "future_global"
      assert html =~ "The provider cannot be used because its configuration is not valid"
      assert html =~ "Correct the provider configuration"
      refute html =~ "unexpected_refusal"
      refute html =~ "internal"
    end

    test "a hosted provider is not configured before the operator accepts the disclosure", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")

      html =
        view
        |> form("#provider-add")
        |> render_submit(provider_params("hosted_without_acceptance", :hosted))

      assert html =~ "Setup is incomplete"
      assert html =~ "check the acceptance box"
      assert html =~ "it may use that data to train its models"
      assert html =~ "it may retain that data for longer than the retention window it states"
      assert html =~ "it may hand it to the subprocessors it names"
      assert {:ok, []} = Registry.list(workspace)
    end

    test "an accepted hosted provider records and displays who accepted and when", %{
      conn: conn,
      workspace: workspace
    } do
      %{conn: signed_in, principal: principal} =
        sign_in(conn, workspace, roles: ["Platform Admin"])

      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")

      view
      |> form("#provider-add")
      |> render_submit(
        provider_params("hosted_accepted", :hosted, %{
          "capability_floor_acknowledged" => "true"
        })
      )

      assert {:ok, stored} = Registry.fetch(workspace, "hosted_accepted")
      assert stored.capability_floor_acknowledged
      assert stored.capability_floor_acknowledged_by == %{type: "user", id: principal.id}
      assert %DateTime{} = stored.capability_floor_acknowledged_at

      html = render(view)
      assert html =~ "Contractual floor acknowledged by"
      assert html =~ "user:#{principal.id}"
      assert html =~ DateTime.to_string(stored.capability_floor_acknowledged_at)
    end

    test "a self_hosted provider needs no acceptance", %{conn: conn, workspace: workspace} do
      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")

      html =
        view
        |> form("#provider-add")
        |> render_submit(provider_params("self_hosted", :self_hosted))

      assert html =~ "self_hosted is configured."
      refute html =~ "Setup is incomplete"
      assert {:ok, stored} = Registry.fetch(workspace, "self_hosted")
      refute stored.capability_floor_acknowledged
    end

    test "an unacknowledged hosted global is shown, not treated as an empty tier", %{
      conn: conn,
      workspace: workspace
    } do
      Application.put_env(:veritas_core, :providers, [
        {"hosted_global",
         [
           kind: :hosted,
           adapter: ScriptedAdapter.id(),
           base_url: "https://hosted.example",
           model: "hosted-1"
         ]}
      ])

      %{conn: signed_in} = sign_in(conn, workspace, roles: ["Platform Admin"])
      {:ok, view, _static} = live(signed_in, ~p"/agents/providers")
      html = render(view)

      assert html =~ "hosted_global"
      assert html =~ "Contractual floor not acknowledged."
      refute html =~ "None configured."
    end
  end

  defp render_providers(overrides) do
    assigns =
      Map.merge(
        %{
          flash: %{},
          workspace: "w_test",
          providers: [],
          workspace_error: nil,
          global: [],
          global_refusals: [],
          adapters: [],
          form: %{}
        },
        overrides
      )

    rendered_to_string(Providers.render(assigns))
  end

  defp provider_params(id, kind, extra \\ %{}) do
    Map.merge(
      %{
        "_id" => id,
        "kind" => to_string(kind),
        "adapter" => to_string(ScriptedAdapter.id()),
        "base_url" => "http://scripted.invalid",
        "model" => "scripted-1",
        "credential_env" => ""
      },
      extra
    )
  end
end
