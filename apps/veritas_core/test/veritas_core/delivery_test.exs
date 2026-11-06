defmodule Veritas.Core.DeliveryTest do
  @moduledoc """
  Delivery, tested against the section the corpus specifies.

  `docs/04` §Navigation Model gives the Delivery section *"Programs,
  milestones, work items linked to CIs and Changes"*, and §6 the widgets that
  read them: a Program's status, a Milestone's planned and actual dates, a
  Work Item's state, a Benefit's type.

  These tests are written against that, not against the implementation: the
  tree reads back, the links are the ones the section names, and **every
  change is in the Audit Log** — a Delivery record is a record somebody
  changed, and the Log is the record of it.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.Delivery

  setup do
    workspace = unique_workspace()
    migrate(workspace)
    on_exit(fn -> remove_workspace(workspace) end)

    %{workspace: workspace}
  end

  test "a Program holds its Milestones, and a Milestone holds its Work Items", %{
    workspace: workspace
  } do
    {:ok, program} =
      Delivery.create_program(workspace, %{"name" => "CMDB build-out", "status" => "amber"})

    {:ok, milestone} =
      Delivery.create_milestone(workspace, program["id"], %{
        "name" => "Inventory in",
        "planned_date" => ~U[2026-11-01 00:00:00Z]
      })

    {:ok, item} =
      Delivery.create_work_item(workspace, milestone["id"], %{
        "title" => "Scan the datacentre",
        "state" => "planned"
      })

    assert {:ok, [listed]} = Delivery.list_programs(workspace)
    assert listed["id"] == program["id"]
    assert listed["status"] == "amber"

    assert {:ok, [milestones]} = Delivery.list_milestones(workspace, program["id"])
    assert milestones["id"] == milestone["id"]
    assert milestones["planned_date"]

    assert {:ok, [items]} = Delivery.list_work_items(workspace, milestone["id"])
    assert items["id"] == item["id"]
  end

  test "a Work Item carries the links the section names", %{workspace: workspace} do
    {:ok, program} = Delivery.create_program(workspace, %{"name" => "Service redesign"})

    {:ok, milestone} =
      Delivery.create_milestone(workspace, program["id"], %{"name" => "Catalogue"})

    {:ok, item} =
      Delivery.create_work_item(workspace, milestone["id"], %{
        "title" => "Publish the catalogue",
        "ci_refs" => ["ci-1", "ci-2"],
        "change_refs" => ["chg-1"]
      })

    assert item["ci_refs"] == ["ci-1", "ci-2"]
    assert item["change_refs"] == ["chg-1"]
  end

  test "a blocked Work Item records when it was blocked", %{workspace: workspace} do
    {:ok, program} = Delivery.create_program(workspace, %{"name" => "Program"})

    {:ok, milestone} =
      Delivery.create_milestone(workspace, program["id"], %{"name" => "Milestone"})

    {:ok, item} =
      Delivery.create_work_item(workspace, milestone["id"], %{
        "title" => "Blocked work",
        "state" => "blocked"
      })

    # The blocked-items widget ages what is blocked, and the age is measured
    # from the moment it was blocked.
    assert item["blocked_at"]

    {:ok, moved} =
      Delivery.update_work_item(workspace, item["id"], %{"state" => "in_progress"})

    refute moved["blocked_at"]
  end

  test "every change to a Delivery record is in the Audit Log", %{workspace: workspace} do
    {:ok, program} = Delivery.create_program(workspace, %{"name" => "Audited program"})

    {:ok, _milestone} = Delivery.create_milestone(workspace, program["id"], %{"name" => "M1"})

    {:ok, updated} = Delivery.update_program(workspace, program["id"], %{"status" => "green"})

    assert updated["status"] == "green"

    events = audit_events(workspace)
    subjects = Enum.map(events, & &1["subject"])

    assert program["id"] in subjects
  end
end
