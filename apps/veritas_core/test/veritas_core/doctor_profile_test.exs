defmodule Veritas.Core.DoctorProfileTest do
  @moduledoc """
  The deployment profile, as the operator sees it.

  `mix veritas.cli doctor` is where an operator finds out what they are
  actually running, and a profile that changes what a role may do is a
  **deployment fact** — so it is on the doctor's report and in the Audit Log.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{Audit, Doctor, Policy}

  describe "the deployment profile" do
    test "is on the report, and the doctor says which one is in force", %{
      workspace: workspace
    } do
      report = Doctor.report(workspace)

      assert report.deployment.profile == Policy.profile_name()
      assert report.deployment.recorded == true
      assert Doctor.format(report) =~ "Deployment profile"
    end

    test "is recorded in the Audit Log as a deployment fact", %{workspace: workspace} do
      Doctor.report(workspace)

      assert {:ok, events} = Audit.entries(workspace)

      deployment = Enum.find(events, &(&1["subject_table"] == "deployment"))

      assert deployment
      assert deployment["to_state"] == Policy.profile_name()
    end

    test "is recorded once, not once per diagnostic", %{workspace: workspace} do
      Doctor.report(workspace)
      Doctor.report(workspace)

      assert {:ok, events} = Audit.entries(workspace)

      deployments = Enum.filter(events, &(&1["subject_table"] == "deployment"))

      assert length(deployments) == 1
    end
  end
end
