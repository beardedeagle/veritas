defmodule Veritas.Web.IncidentBindingComponentsTest do
  @moduledoc """
  Exercises rendered answer controls and their exported transport boundary.

  Real workflow-definition validation and Incident binding projection are used;
  these tests do not start a Store or qualify workflow persistence, required-answer
  enforcement, authority, or the full Incident lifecycle.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Veritas.Core.Tickets.Incident
  alias Veritas.Core.Tickets
  alias Veritas.Core.Workflows
  alias Veritas.Web.WorkflowLive.Components

  test "typed references cover every supported ticket type and preserve the stored identifier" do
    prefixes = %{
      "incident" => "INC",
      "service_request" => "REQ",
      "change" => "CHG",
      "problem" => "PRB",
      "vulnerability" => "VUL"
    }

    assert Enum.sort(Map.keys(prefixes)) == Enum.sort(Tickets.ticket_types())

    for {type, prefix} <- prefixes do
      assert byte_size(prefix) == 3
      ticket = %{"id" => "01fe4d77fe82555568", "ticket_type" => type}
      reference = prefix <> ticket["id"]
      assert Tickets.reference(ticket) == reference
      assert byte_size(reference) == 3 + byte_size(ticket["id"])
      assert Tickets.parse_reference(reference) == {:ok, type, ticket["id"]}

      assert Tickets.parse_reference(String.downcase(prefix) <> "Mixed_Case_01") ==
               {:ok, type, "Mixed_Case_01"}
    end

    for invalid <- [
          nil,
          "",
          "INC",
          "XYZ01fe4d77fe82555568",
          "INC../private",
          "INCticket/other",
          "INCticket?workspace=other"
        ] do
      assert Tickets.parse_reference(invalid) == :error
    end
  end

  test "a populated record submits only changed fields, preserving blanks and recorded attribution" do
    notice = %{
      "reference" => "mock:notice",
      "channel" => "email",
      "direction" => "outbound",
      "recipient" => "requester@example.invalid",
      "recorded_by" => "operator",
      "recorded_at" => "2026-11-08T12:00:00Z"
    }

    saved = %{
      "title" => "Existing incident",
      "description" => "Original description",
      "impact" => "team",
      "notification_evidence" => notice,
      "track_plan" => %{"steps" => ["Check the host", "Verify recovery"]}
    }

    params = %{
      "title" => saved["title"],
      "description" => saved["description"],
      "domain_fields" => %{
        "impact" => "team",
        "urgency" => "",
        "affected_ci_ids" => "",
        "notification_evidence" => Map.drop(notice, ~w(recorded_by recorded_at)),
        "track_plan" => %{
          "steps" => "Check the host\nVerify recovery",
          "reference" => "",
          "text" => ""
        }
      }
    }

    assert Components.incident_record_fields(params, saved) == %{}

    assert Components.incident_record_fields(
             put_in(params, ["domain_fields", "impact"], "department"),
             saved
           ) == %{"impact" => "department"}

    assert Components.incident_record_fields(%{"description" => ""}, saved) == %{
             "description" => ""
           }

    assert Components.incident_record_fields(
             %{"domain_fields" => %{"affected_ci_ids" => ""}},
             %{"affected_ci_ids" => ["existing_ci"]}
           ) == %{"affected_ci_ids" => []}

    assert Components.incident_record_fields(
             %{"domain_fields" => %{"unrecognised" => "value"}},
             saved
           ) == %{"unrecognised" => "value"}
  end

  test "creation submits supplied facts and omits blank optional controls" do
    params = %{
      "domain_fields" => %{
        "impact" => "team",
        "urgency" => "",
        "assignee" => "   ",
        "affected_ci_ids" => "ci_a\nci_b",
        "priority_override" => %{"reason" => "", "expires_at" => ""},
        "notification_evidence" => %{"reference" => "mail:123", "text" => ""}
      }
    }

    assert Components.incident_creation_fields(params) == %{
             "impact" => "team",
             "affected_ci_ids" => ["ci_a", "ci_b"],
             "notification_evidence" => %{"reference" => "mail:123"}
           }

    assert Components.incident_creation_fields(%{}) == %{}
  end

  test "bound select preserves its pinned raw choice through canonical Incident projection" do
    field = %{
      "key" => "priority_choice",
      "label" => "Priority",
      "type" => "select",
      "options" => ["High"],
      "required" => true,
      "binding" => "priority"
    }

    step = validated_step(field)
    document = render_field(hd(step["fields"]), "High")
    select = LazyHTML.query(document, ~s(select[name="answers[priority_choice]"]))

    assert LazyHTML.attribute(select, "name") == ["answers[priority_choice]"]
    assert select |> LazyHTML.query("option") |> LazyHTML.attribute("value") == ["", "High"]

    assert [submitted] =
             select |> LazyHTML.query("option[selected]") |> LazyHTML.attribute("value")

    assert submitted == "High"
    answers = Components.prepare_answers(step, %{"priority_choice" => submitted})
    assert answers == %{"priority_choice" => "High"}
    assert Incident.bound_fields(step, answers, %{}) == {:ok, %{"priority" => "P2"}}
  end

  test "explicitly submitted empty bound CI textarea remains an authoritative empty list" do
    field = %{
      "key" => "affected",
      "label" => "Affected CIs",
      "type" => "textarea",
      "required" => true,
      "binding" => "affected_ci_ids"
    }

    step = validated_step(field)
    document = render_field(hd(step["fields"]), nil)
    textarea = LazyHTML.query(document, ~s(textarea[name="answers[affected]"]))

    assert LazyHTML.attribute(textarea, "name") == ["answers[affected]"]
    submitted = LazyHTML.text(textarea)
    assert submitted == ""

    answers = Components.prepare_answers(step, %{"affected" => submitted})
    assert answers == %{"affected" => []}
    assert Incident.bound_fields(step, answers, %{}) == {:ok, %{"affected_ci_ids" => []}}
  end

  test "omitted bound CI answer stays absent rather than asserting empty membership" do
    step =
      validated_step(%{
        "key" => "affected",
        "label" => "Affected CIs",
        "type" => "textarea",
        "required" => true,
        "binding" => "affected_ci_ids"
      })

    answers = Components.prepare_answers(step, %{})
    assert answers == %{}
    assert Incident.bound_fields(step, answers, %{}) == {:ok, %{}}
  end

  test "unbound select keeps its choices and does not infer a priority binding from its key" do
    field = %{
      "key" => "priority",
      "label" => "Priority",
      "type" => "select",
      "options" => ["High", "Customer-specific"],
      "required" => true
    }

    step = validated_step(field)
    document = render_field(hd(step["fields"]), "High")
    select = LazyHTML.query(document, ~s(select[name="answers[priority]"]))

    assert LazyHTML.attribute(select, "name") == ["answers[priority]"]

    assert select |> LazyHTML.query("option") |> LazyHTML.attribute("value") ==
             ["", "High", "Customer-specific"]

    assert [submitted] =
             select |> LazyHTML.query("option[selected]") |> LazyHTML.attribute("value")

    assert submitted == "High"
    answers = Components.prepare_answers(step, %{"priority" => submitted})
    assert answers == %{"priority" => "High"}
    assert Incident.bound_fields(step, answers, %{}) == {:ok, %{}}
  end

  test "unbound CI-named textarea keeps its free text instead of becoming domain membership" do
    field = %{
      "key" => "affected_ci_ids",
      "label" => "CI notes",
      "type" => "textarea",
      "required" => false
    }

    step = validated_step(field)
    document = render_field(hd(step["fields"]), "ci_a\nci_b")
    textarea = LazyHTML.query(document, ~s(textarea[name="answers[affected_ci_ids]"]))

    assert LazyHTML.attribute(textarea, "name") == ["answers[affected_ci_ids]"]
    submitted = LazyHTML.text(textarea)
    assert submitted == "ci_a\nci_b"

    answers = Components.prepare_answers(step, %{"affected_ci_ids" => submitted})
    assert answers == %{"affected_ci_ids" => "ci_a\nci_b"}
    assert Incident.bound_fields(step, answers, %{}) == {:ok, %{}}
  end

  defp validated_step(field) do
    definition =
      Workflows.template("incident")
      |> update_in(["steps"], fn [intake | rest] ->
        [Map.put(intake, "fields", [field]) | rest]
      end)

    assert {:ok, validated} = Workflows.validate(definition)
    hd(validated["steps"])
  end

  defp render_field(field, value) do
    render_component(&Components.answer_field/1, field: field, value: value)
    |> LazyHTML.from_fragment()
  end
end
