defmodule Veritas.Core.Tickets.IncidentTimezoneProviderTest do
  @moduledoc """
  The pinned real IANA provider (`tz` 0.28.4) through the existing clock and
  policy seams.

  Governing: 02-contract.md sections 6 and 7 (provider injected, rules version
  independent, gap/fold never guessed, `:timezone_provider_unavailable` on
  unsupported evaluation); owner approval of the pinned replaceable tz 0.28.4
  dependency with automatic updates disabled (brief, "Explicit owner timezone
  approval", 2026-11-08).

  Every provider use here is the real `Tz.TimeZoneDatabase` module — this file
  adds no synthetic provider, because the synthetic-only proof already exists
  in the hold-accounting and closure suites. Package facts are pinned to the
  official v0.28.4 sources (github.com/mathieuprog/tz at tag v0.28.4):
  `Tz.TimeZoneDatabase` implements `Calendar.TimeZoneDatabase`; the bundle
  ships IANA tzdata2026d reported by `Tz.iana_version/0` (defdelegate to
  `Tz.PeriodsProvider`); `mix.exs` declares no application `mod:`, so the VM
  never starts any tz process on its own; `Tz.UpdatePeriodically.start_link/1`
  raises before any HTTP work when the `:tz, :iana_version` config is forced
  (`update_periodically.ex:18-21`), which is the package's own lock for the
  disabled-updates contract; `Tz.WatchPeriodically.start_link/1` carries no
  such guard and reaches the network on start, so it is never started here.

  tz is a dependency addition owned by DevOps (brief, batch_4be11ae3baa9). If
  the dependency is not compiled into this snapshot, setup fails with an
  explicit prerequisite message: that is a prerequisite failure, not a RED
  assertion. No runtime or acceptance claim is made by authoring. Pause/hold
  semantics are untouched by this file: no test asserts or forbids pausing;
  the ruling of 2026-11-08 (msg-user-v1-QKpcwZ6po9Mjs-hVdvPH_dIbdBWqXNdKN22soCV2VnY)
  preserves all pause/hold/resume behavior and only excludes a datastore-outage
  auto-pause, which this file does not approach.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Principal
  alias Veritas.Core.Tickets
  alias Veritas.Core.Tickets.IncidentClock
  alias Veritas.Core.Test.StoreCase
  alias Veritas.Store
  alias Veritas.Store.Memory

  @provider Tz.TimeZoneDatabase
  # The IANA release bundled by the pinned tz 0.28.4 (official README). The
  # tests read the real `Tz.iana_version/0` and pin it to this value, so a
  # resolution to any other package version fails honestly instead of passing.
  # The canonical classification vocabulary (incident_policy.ex:24-25); the
  # fixture covers every pair so publication readiness is complete.
  @impacts ~w(individual team department organization business_critical)
  @urgencies ~w(immediate high medium low)
  @pinned_iana "2026d"
  @zone "America/New_York"
  @hour_us 3_600_000_000
  @days ~w(mon tue wed thu fri sat sun)

  setup do
    previous_database = Application.get_env(:veritas_core, :incident_timezone_database)
    previous_rules = Application.get_env(:veritas_core, :incident_timezone_rules_version)

    on_exit(fn ->
      if is_nil(previous_database),
        do: Application.delete_env(:veritas_core, :incident_timezone_database),
        else: Application.put_env(:veritas_core, :incident_timezone_database, previous_database)

      if is_nil(previous_rules),
        do: Application.delete_env(:veritas_core, :incident_timezone_rules_version),
        else: Application.put_env(:veritas_core, :incident_timezone_rules_version, previous_rules)

      :ok
    end)

    # Prerequisite, not a verdict: tz 0.28.4 is DevOps's dependency addition.
    # `Code.ensure_loaded?/1` returns a boolean; the required module is the
    # real `Tz.TimeZoneDatabase`, not the Elixir UTC-only stand-in.
    assert Code.ensure_loaded?(Tz),
           "prerequisite: tz is not compiled into this snapshot — the pinned " <>
             "0.28.4 dependency addition belongs to DevOps (brief, " <>
             "batch_4be11ae3baa9); this failure is not a RED assertion"

    assert Code.ensure_loaded?(@provider),
           "prerequisite: Tz.TimeZoneDatabase unavailable — dependency " <>
             "addition not compiled; not a RED assertion"

    assert function_exported?(Tz, :iana_version, 0),
           "prerequisite: Tz.iana_version/0 missing from the resolved tz — " <>
             "not the pinned 0.28.4 API"

    assert Tz.iana_version() == @pinned_iana,
           "prerequisite: resolved tz reports #{inspect(Tz.iana_version())}, " <>
             "not the pinned tzdata#{@pinned_iana} of 0.28.4"

    {:ok, iana: Tz.iana_version()}
  end

  # The package evidence required by the approval: the real module implements
  # both behaviour callbacks and the bundle is the pinned IANA release.
  test "the pinned provider is tz 0.28.4 with truthful bundled rules" do
    assert function_exported?(@provider, :time_zone_periods_from_wall_datetime, 2)
    assert function_exported?(@provider, :time_zone_period_from_utc_iso_days, 2)
    assert Tz.iana_version() == @pinned_iana
  end

  # The disabled-updates contract, discriminated against the package's own
  # integration seam. v0.28.4's application block declares no callback
  # module, so starting :tz launches no process at all; the empty :mod key is
  # OTP's representation of that (observed against the real dependency). The
  # updater's absence is discriminated by the package's own pin guard below —
  # not by whether the inert :tz library application appears in the started
  # list, which would say nothing about an updater process.
  test "the pinned configuration locks the opt-in updater and nothing auto-starts" do
    assert Application.spec(:tz, :mod) == []

    # `function_exported?/3` inspects only already-loaded modules, so the
    # opt-in processes must be loaded explicitly before their exports are
    # checked. `Code.ensure_loaded/1` performs pure code loading — it never
    # runs a module's start_link, so no updater or network is involved.
    assert {:module, Tz.UpdatePeriodically} = Code.ensure_loaded(Tz.UpdatePeriodically)
    assert {:module, Tz.WatchPeriodically} = Code.ensure_loaded(Tz.WatchPeriodically)
    assert function_exported?(Tz.UpdatePeriodically, :child_spec, 1)
    assert function_exported?(Tz.WatchPeriodically, :child_spec, 1)

    previous = Application.get_env(:tz, :iana_version)
    Application.put_env(:tz, :iana_version, @pinned_iana)

    # With the IANA version forced, the opt-in updater REFUSES to start — its
    # first check, before any HTTP client or update work
    # (update_periodically.ex:18-21). The unpinned path is deliberately not
    # exercised: it would configure an HTTP client and enter the update path.
    # `Tz.WatchPeriodically` carries no pin guard and reaches the network on
    # start, so it is never started by Veritas at all.
    try do
      assert_raise RuntimeError,
                   ~r/has been forced through the :iana_version config/,
                   fn -> Tz.UpdatePeriodically.start_link([]) end
    after
      if is_nil(previous),
        do: Application.delete_env(:tz, :iana_version),
        else: Application.put_env(:tz, :iana_version, previous)
    end
  end

  # The configured seam (application env) serves policy publication, and the
  # published calendar row carries the real bundled IANA version — not a
  # hand-written rules string.
  test "the configured provider publishes calendars stamped with the real bundled rules", %{iana: iana} do
    use_memory_store()
    workspace = StoreCase.unique_workspace()

    on_exit(fn ->
      remove_memory_workspace(workspace)
    end)

    admin = Principal.new("tz_policy_admin", workspace, [:platform_admin], kind: :human)
    Application.put_env(:veritas_core, :incident_timezone_database, @provider)
    Application.put_env(:veritas_core, :incident_timezone_rules_version, iana)

    assert {:ok, draft} = Tickets.save_incident_policy(workspace, ny_document(), admin, nil)
    # No explicit timezone keys: publication must use the configured provider.
    assert {:ok, policy} =
             Tickets.publish_incident_policy(workspace, admin, draft.policy_revision, approve: true)

    assert policy.readiness.missing == []

    assert {:ok, version} =
             Store.transaction(workspace, fn tx ->
               Store.fetch(tx, :incident_policy_version, policy.active_version)
             end)

    calendar_id = version["definition"]["calendar_versions"]["main"]

    assert {:ok, row} =
             Store.transaction(workspace, fn tx -> Store.fetch(tx, :incident_calendar_version, calendar_id) end)

    assert row["timezone"] == @zone
    assert row["timezone_rules_version"] == iana
    assert row["definition"]["timezone"] == @zone
    assert {:ok, :intact} = Veritas.Core.Audit.verify(workspace)
  end

  # The real 2026 transitions: March 8 loses the 02:00 hour (a 22-hour slice of
  # the 00:00–23:00 working window) and November 1 repeats it (a 24-hour slice).
  test "real IANA transitions produce the working-day lengths 2026 actually had", %{iana: iana} do
    calendar = ny_calendar("00:00", "23:00", @days)
    opts = tz_opts(iana)

    # Control: the Monday after spring-forward, a normal 23-hour window.
    assert {:ok, us} =
             IncidentClock.duration(~U[2026-03-09T04:00:00Z], ~U[2026-03-10T03:00:00Z],
               business_target(), calendar, opts)

    assert us == 23 * @hour_us

    # Spring forward 2026-03-08: 00:00 EST (05:00Z) to 23:00 EDT (03:00Z next
    # day) is 22 real hours — the nonexistent hour is never counted.
    assert {:ok, us} =
             IncidentClock.duration(~U[2026-03-08T05:00:00Z], ~U[2026-03-09T03:00:00Z],
               business_target(), calendar, opts)

    assert us == 22 * @hour_us

    # Fall back 2026-11-01: 00:00 EDT (04:00Z) to 23:00 EST (04:00Z next day)
    # is 24 real hours — the repeated hour is real time and is counted once.
    assert {:ok, us} =
             IncidentClock.duration(~U[2026-11-01T04:00:00Z], ~U[2026-11-02T04:00:00Z],
               business_target(), calendar, opts)

    assert us == 24 * @hour_us
  end

  # A weekly window whose start lands inside the spring gap or whose whole
  # window is the fall fold refuses at evaluation with the exact policy
  # errors, while the publication probe (a fixed 2000-01-15 instant) still
  # accepts the calendar — the boundary refusal is evaluation-time by design.
  test "gap and fold schedule boundaries refuse instead of guessing a side", %{iana: iana} do
    gap_calendar = ny_calendar("02:00", "03:00", @days)
    fold_calendar = ny_calendar("01:00", "02:00", @days)
    opts = tz_opts(iana)

    assert :ok = IncidentClock.validate_calendar(gap_calendar, opts)
    assert :ok = IncidentClock.validate_calendar(fold_calendar, opts)

    assert {:error, {:policy_invalid, errors}} =
             IncidentClock.duration(~U[2026-03-06T20:00:00Z], ~U[2026-03-10T20:00:00Z],
               business_target(), gap_calendar, opts)

    assert errors == %{"calendars.timezone" => :nonexistent_time}

    assert {:error, {:policy_invalid, errors}} =
             IncidentClock.duration(~U[2026-10-30T20:00:00Z], ~U[2026-11-03T20:00:00Z],
               business_target(), fold_calendar, opts)

    assert errors == %{"calendars.timezone" => :ambiguous_time}

    # The refusal is boundary-specific: the same fold calendar evaluates its
    # unambiguous 01:00–02:00 EST window (06:00Z–07:00Z) normally on a
    # transition-free date.
    assert {:ok, us} =
             IncidentClock.duration(~U[2026-11-10T06:00:00Z], ~U[2026-11-10T07:00:00Z],
               business_target(), fold_calendar, opts)

    assert us == @hour_us
  end

  # A deadline that must cross the spring-forward weekend follows the real
  # rules: Friday still holds 8 working hours (15:00–23:00 EST), the weekend
  # windows are empty, and the remaining 2 hours land on Monday 02:00 EDT.
  test "deadlines crossing the transition weekend follow the real rules", %{iana: iana} do
    calendar = ny_calendar("00:00", "23:00", ~w(mon tue wed thu fri))
    opts = tz_opts(iana)
    target = %{"basis" => "business", "amount" => 10, "unit" => "hours"}

    assert {:ok, due} = IncidentClock.deadline(~U[2026-03-06T20:00:00Z], target, calendar, opts)
    assert DateTime.compare(due, ~U[2026-03-09T06:00:00Z]) == :eq

    # Elapsed control over the same target ignores the calendar entirely.
    elapsed = %{"basis" => "elapsed", "amount" => 10, "unit" => "hours"}
    assert {:ok, naive} = IncidentClock.deadline(~U[2026-03-06T20:00:00Z], elapsed, calendar, opts)
    assert DateTime.compare(naive, ~U[2026-03-07T06:00:00Z]) == :eq
  end

  # The rules binding refuses a calendar whose recorded rules version differs
  # from the running provider's bundle: recorded history is refused as
  # unevaluable, never silently reinterpreted under newer rules.
  test "a calendar recorded under different rules is refused, not reinterpreted", %{iana: iana} do
    opts = tz_opts(iana)

    assert {:ok, evaluation} =
             IncidentClock.evaluate(evaluation_clock(), [], ~U[2026-03-09T15:00:00Z],
               evaluation_opts(opts, iana))

    assert evaluation.calendar_version == "cal_1"
    assert evaluation.priority == "P3"
    assert is_integer(evaluation.budget_us) and evaluation.budget_us > 0
    assert is_struct(evaluation.deadline, DateTime)

    stale = %{"cal_1" => %{"timezone_rules_version" => "2026b",
      "definition" => ny_calendar("09:00", "17:00", @days)}}

    assert {:error, :timezone_provider_unavailable} =
             IncidentClock.evaluate(evaluation_clock(), [], ~U[2026-03-09T15:00:00Z],
               evaluation_opts(opts, iana) |> Keyword.put(:calendars, stale))
  end

  # Honest refusals: nothing substitutes UTC, guesses a side, or invents a
  # provider. Only the provider condition varies here — the calendar fixture
  # is valid and complete.
  test "missing and unsupported providers refuse exactly as unavailable" do
    Application.delete_env(:veritas_core, :incident_timezone_database)
    Application.delete_env(:veritas_core, :incident_timezone_rules_version)
    calendar = ny_calendar("09:00", "17:00", @days)

    error = {:error, :timezone_provider_unavailable}

    assert error ==
             IncidentClock.duration(~U[2026-03-09T14:00:00Z], ~U[2026-03-09T22:00:00Z],
               business_target(), calendar, [])

    assert error ==
             IncidentClock.duration(~U[2026-03-09T14:00:00Z], ~U[2026-03-09T22:00:00Z],
               business_target(), calendar,
               timezone_database: Calendar.UTCOnlyTimeZoneDatabase,
               timezone_rules_version: @pinned_iana)

    assert error ==
             IncidentClock.duration(~U[2026-03-09T14:00:00Z], ~U[2026-03-09T22:00:00Z],
               business_target(), calendar,
               timezone_database: NoSuchTimezoneProvider,
               timezone_rules_version: @pinned_iana)

    assert error == IncidentClock.validate_calendar(calendar, [])
  end

  # Only the rules condition varies here: the real provider stays configured
  # and the draft is a valid complete fixture, so the refusal isolates the
  # missing rules version — and the independent readback proves nothing was
  # persisted.
  test "publication without a configured rules version refuses as unavailable", %{iana: iana} do
    use_memory_store()
    workspace = StoreCase.unique_workspace()

    on_exit(fn ->
      remove_memory_workspace(workspace)
    end)

    admin = Principal.new("tz_refusal_admin", workspace, [:platform_admin], kind: :human)
    Application.put_env(:veritas_core, :incident_timezone_database, @provider)
    Application.delete_env(:veritas_core, :incident_timezone_rules_version)

    assert {:ok, draft} = Tickets.save_incident_policy(workspace, ny_document(), admin, nil)
    assert {:error, :timezone_provider_unavailable} =
             Tickets.publish_incident_policy(workspace, admin, draft.policy_revision, approve: true)

    # Independent persisted readback: the refused publication left no policy
    # version and no calendar version behind.
    assert {:ok, []} =
             Store.transaction(workspace, fn tx ->
               Store.list(tx, :incident_policy_version, %{where: [workspace: workspace]})
             end)

    assert {:ok, []} =
             Store.transaction(workspace, fn tx ->
               Store.list(tx, :incident_calendar_version, %{where: [workspace: workspace]})
             end)

    assert {:ok, :intact} = Veritas.Core.Audit.verify(workspace)
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp tz_opts(iana) do
    [timezone_database: @provider, timezone_rules_version: iana]
  end

  defp business_target do
    %{"basis" => "business", "amount" => 1, "unit" => "hours"}
  end

  # The calendar grammar requires every weekday key (incident_clock.ex:433-458
  # refuses absent days; publication completeness requires all seven), so the
  # excluded days carry explicit empty intervals.
  defp ny_calendar(from, until, days) do
    %{"timezone" => @zone,
      "weekly" => Map.new(@days, fn day -> {day, if(day in days, do: [[from, until]], else: [])} end),
      "nonworking_dates" => [], "exceptions" => []}
  end

  defp ny_document do
    rules = for impact <- @impacts, urgency <- @urgencies,
      do: %{"impact" => impact, "urgency" => urgency, "priority" => "P3"}

    targets = Map.new(~w(P1 P2 P3 P4), fn priority ->
      {priority, %{
        "response" => %{"amount" => 1, "unit" => "hours", "basis" => "business", "calendar" => "main"},
        "resolution" => %{"amount" => 24, "unit" => "hours", "basis" => "business", "calendar" => "main"}
      }}
    end)

    %{"priority_rules" => rules, "sla_targets" => targets, "reopen_resolution" => "new_cycle",
      "calendars" => %{"main" => ny_calendar("09:00", "17:00", ~w(mon tue wed thu fri))}}
  end

  # A stopped-free resolution clock bound to the fixture policy/calendar, in
  # the shape `plan/7` and `evaluate/4` bind against (incident_clock.ex:308-323).
  defp evaluation_clock do
    %{"id" => "clock_evaluate_1", "workspace" => "tz_evaluate", "ticket" => "t_evaluate_1",
      "kind" => "resolution", "cycle" => 1, "domain_revision" => 2,
      "history_complete" => true, "started_at" => "2026-03-09T14:00:00Z",
      "stopped_at" => nil, "qualified_pause_us" => 0, "current_hold" => nil,
      "priority" => "P3", "policy_version" => "pol_1", "calendar_version" => "cal_1",
      "carried_elapsed_us" => 0}
  end

  defp evaluation_opts(base_opts, iana) do
    target = %{"basis" => "business", "amount" => 8, "unit" => "hours", "calendar" => "main"}

    policy = %{"definition" => %{"sla_targets" => %{"P3" => %{"response" => target, "resolution" => target}}}}

    base_opts
    |> Keyword.put(:policies, %{"pol_1" => policy})
    |> Keyword.put(:calendars, %{"cal_1" => %{
      "timezone_rules_version" => iana,
      "definition" => ny_calendar("09:00", "17:00", @days)
    }})
  end

  # test_helper.exs configures Surreal (its own instance, or the store at
  # VERITAS_SURREAL_URL) for the suite. The policy cases here must not touch
  # that store: cleanup is registered before the mutation, the Memory Adapter
  # is selected explicitly, and the original configuration is restored, so an
  # unrelated Workspace or the owner's store is never written.
  defp use_memory_store do
    previous = Application.get_env(:veritas_core, :store)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:veritas_core, :store),
        else: Application.put_env(:veritas_core, :store, previous)
    end)

    start_memory_once()
    Application.put_env(:veritas_core, :store, Veritas.Store.Memory)
  end

  defp start_memory_once do
    if is_nil(Process.whereis(Memory.Server)) do
      start_supervised!(Memory.Server)
    end
  end

  defp remove_memory_workspace(workspace) do
    if Process.whereis(Memory.Server) do
      :sys.replace_state(Memory.Server, fn state ->
        outbox = state.outbox |> Map.delete(workspace) |> Map.update(:__all__, [], fn rows ->
          Enum.reject(rows, &(&1["workspace"] == workspace))
        end)
        %{state | workspaces: Map.delete(state.workspaces, workspace), outbox: outbox}
      end)
    end

    :ok
  end
end
