defmodule Veritas.Core.FlakinessTest do
  @moduledoc """
  The flakiness policy, enforced rather than described.

  `docs/12` §Flakiness and Quarantine Policy says three things that can be
  checked mechanically, so this module checks them:

    * **no test blocks on a sleep.** A sleep is a race with the scheduler
      wearing a disguise: it passes on a fast machine and fails on a slow
      one. The one exception is a bounded readiness wait in the integration
      harness, and it is registered.

    * **no test depends on the wall clock.** A test that asserts against
      `DateTime.utc_now()` is asserting against the machine it runs on. The
      one exception is this file, which compares a registry expiry against
      today's date — a governance check, not a behavioural one.

    * **nothing stays quarantined forever.** Every registry entry carries a
      reason, an owner, a reference and an expiry, and an expired entry fails
      this suite rather than passing quietly.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Test.Quarantine

  @root Path.expand("../../../..", __DIR__)

  # Built from fragments so this file does not match its own scan.
  @sleep_patterns ["Process" <> ".sleep", "System" <> ".sleep", ":timer" <> ".sleep"]
  @wall_clock_patterns ["DateTime" <> ".utc_now", "DateTime" <> ".now", ":os." <> "timestamp"]

  describe "the registry" do
    test "every entry carries a reason, an owner, a reference and an expiry" do
      for entry <- Quarantine.entries() do
        assert is_binary(entry.reason) and entry.reason != "",
               "#{entry.id} has no reason"

        assert is_binary(entry.owner) and entry.owner != "",
               "#{entry.id} has no owner"

        assert is_binary(entry.issue) and entry.issue != "",
               "#{entry.id} has no reference"

        assert match?(%Date{}, entry.expires), "#{entry.id} has no expiry"
      end
    end

    test "no entry has expired" do
      today = Date.utc_today()

      expired =
        for entry <- Quarantine.entries(), Quarantine.expired?(entry, today), do: entry.id

      assert expired == [],
             "these entries have expired and must be fixed or renewed: #{Enum.join(expired, ", ")}"
    end

    test "the ids are unique" do
      ids = Enum.map(Quarantine.entries(), & &1.id)

      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "the suite" do
    test "no test blocks on a sleep" do
      unregistered = unregistered_offenders(@sleep_patterns)

      assert unregistered == [],
             "these files block on a sleep, which is a race in disguise: " <>
               Enum.map_join(unregistered, ", ", fn {path, pattern} -> "#{path} (#{pattern})" end)
    end

    test "no test depends on the wall clock" do
      unregistered = unregistered_offenders(@wall_clock_patterns)

      assert unregistered == [],
             "these files depend on the wall clock: " <>
               Enum.map_join(unregistered, ", ", fn {path, pattern} -> "#{path} (#{pattern})" end)
    end

    test "the tests that need an exception have one registered" do
      # Every file that uses a sleep or the wall clock must be registered as a
      # policy exception, or the two rules above fail.
      registered = Quarantine.allowed_wait_files()

      for {path, _pattern} <- offenders(@sleep_patterns) do
        assert Enum.any?(registered, &String.contains?(path, &1)),
               "#{path} uses a wait and is not registered as a policy exception"
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp offenders(patterns) do
    for path <- test_files(),
        pattern <- patterns,
        String.contains?(File.read!(path), pattern),
        not exempt?(path),
        do: {path, pattern}
  end

  # The offenders that no registered exception covers.
  defp unregistered_offenders(patterns) do
    registered = Quarantine.allowed_wait_files()

    for {path, pattern} <- offenders(patterns),
        not Enum.any?(registered, &String.contains?(path, &1)),
        do: {path, pattern}
  end

  # These files are exempt: the policy check itself, and the registry it
  # reads. Both have to name the thing they are about — the check reads
  # today's date to know whether an entry has expired, and the registry names
  # the pattern it registers — and the scanner reads a file's text rather than
  # its code.
  defp exempt?(path) do
    String.ends_with?(path, "flakiness_test.exs") or
      String.ends_with?(path, "quarantine.ex")
  end

  defp test_files do
    Path.wildcard(Path.join(@root, "apps/*/test/**/*.{ex,exs}"))
  end
end
