defmodule Veritas.Core.StoreInjectionTest do
  @moduledoc """
  The datastore's injection defences.

  Two defects made the Adapter's statement builder unsafe, and both are
  proved here by their effect rather than by their shape:

    * a **reference field** — a field typed `record<user>` and the like — was
      interpolated into the statement as free text, so a value that closed
      the literal and appended a statement of its own was executed;
    * a **filter value** was escaped for the quote but not for the
      backslash, so a value ending in an odd number of backslashes escaped
      the closing quote and the *next* value was read as an expression
      instead of a string.

  A test that only proves the payload was refused by a happy path is weak.
  Each of these asserts what the payload would have done if it had run: the
  row it would have rewritten is unchanged, and the rows it would have
  returned are not returned.
  """
  use Veritas.Core.Test.StoreCase, async: false

  alias Veritas.Core.{CI, Tickets}
  alias Veritas.Store.Error

  @actor %{type: "user", id: "u1"}

  # A payload that closes the literal, completes the remaining SET fields,
  # terminates the statement and appends another one. The appended statement
  # rewrites a row in another table.
  defp closing_payload(workspace) do
    "x'), sequence = 1, state = 'new', ticket_type = 'incident', title = 'INJECTED', " <>
      "workspace = type::record('workspace', '#{workspace}'); " <>
      "UPDATE ci SET name = 'INJECTED-BY-INJECTION' WHERE id != 'zzz'; --"
  end

  defp attrs(requester) do
    %{"title" => "Checkout is down", "requester" => requester, "priority" => "high"}
  end

  describe "a reference field" do
    test "carries a record id, and the id round-trips", %{workspace: workspace} do
      assert {:ok, ticket} = Tickets.open(workspace, "incident", attrs("u1"), @actor)
      assert ticket["requester"] == "u1"

      assert [row] = rows(workspace, :ticket)
      assert row["requester"] == "u1"
    end

    test "is refused when the value is not an id", %{workspace: workspace} do
      assert {:error, %Error{code: :invalid_request, message: message}} =
               Tickets.open(workspace, "incident", attrs("Alice Smith"), @actor)

      # The refusal says what is wrong without quoting the value back: a
      # refusal that quotes the input is a refusal that helps the next try.
      assert message =~ "record id"
      refute message =~ "Alice Smith"
      assert [] = rows(workspace, :ticket)
    end

    test "cannot close the literal and append a statement of its own", %{workspace: workspace} do
      # The row the payload would rewrite if it were executed.
      {:ok, _ci} = CI.create(workspace, %{"ci_type" => "container", "name" => "target-01"})

      assert [%{"name" => "target-01"}] = rows(workspace, :ci)
      before = length(audit_events(workspace))

      assert {:error, %Error{code: :invalid_request}} =
               Tickets.open(workspace, "incident", attrs(closing_payload(workspace)), @actor)

      # The appended statement did not run: the row it would have rewritten
      # is untouched.
      assert [%{"name" => "target-01"}] = rows(workspace, :ci)

      # And nothing was written at all: no ticket, and no new audit event.
      assert [] = rows(workspace, :ticket)
      assert length(audit_events(workspace)) == before
    end

    test "cannot append a statement that writes to the Audit Log", %{workspace: workspace} do
      before = length(audit_events(workspace))

      payload =
        "x'), sequence = 1, state = 'new', ticket_type = 'incident', title = 'FORGED', " <>
          "workspace = type::record('workspace', '#{workspace}'); " <>
          "UPSERT audit_event:forged SET actor_id = 'ceo', to_state = 'closed', hash = 'x'; --"

      assert {:error, %Error{code: :invalid_request}} =
               Tickets.open(workspace, "incident", attrs(payload), @actor)

      # The Audit Log is exactly as it was: no forged row, and no broken
      # chain.
      assert length(audit_events(workspace)) == before
      assert {:ok, :intact} = Veritas.Core.Audit.verify(workspace)
    end
  end

  describe "a filter value" do
    setup %{workspace: workspace} do
      open_incident(workspace, %{"title" => "one"})
      open_incident(workspace, %{"title" => "two"})
      :ok
    end

    test "still filters", %{workspace: workspace} do
      assert {:ok, tickets} = Tickets.list(workspace, ticket_type: "incident")
      assert length(tickets) == 2

      assert {:ok, []} = Tickets.list(workspace, ticket_type: "nonexistent_type")
    end

    test "cannot become an expression when it ends in a backslash", %{workspace: workspace} do
      # The filter that matches nothing.
      assert {:ok, []} = Tickets.list(workspace, ticket_type: "nonexistent_type")

      # The same filter, with a value that used to escape the closing quote
      # and let the next value be read as an expression.
      assert {:ok, []} =
               Tickets.list(workspace, ticket_type: "x\\", state: " OR true --")

      # And the rows are still there: the filter hid them, it did not
      # remove them.
      assert {:ok, tickets} = Tickets.list(workspace, ticket_type: "incident")
      assert length(tickets) == 2
    end

    test "cannot become an expression when it contains a quote", %{workspace: workspace} do
      assert {:ok, []} = Tickets.list(workspace, ticket_type: "x' OR '1'='1")
      assert {:ok, []} = Tickets.list(workspace, state: "new' OR state = 'new")
    end
  end

  describe "the other interpolated values" do
    test "a workspace name that is not an id is refused", %{workspace: workspace} do
      assert {:error, %Error{code: :invalid_request, message: message}} =
               Veritas.Store.transaction("bad workspace; REMOVE DATABASE x", fn tx ->
                 Veritas.Store.list(tx, :ticket, %{where: [], order_by: []})
               end)

      assert message =~ "workspace name"
      # The Workspace it was asked for is untouched.
      assert {:ok, _rows} =
               Veritas.Store.transaction(workspace, fn tx ->
                 Veritas.Store.list(tx, :ticket, %{where: [], order_by: []})
               end)
    end

    test "a chunk index that is not a number is refused", %{workspace: workspace} do
      chunks = [
        %{
          "id" => "c0",
          "chunk_index" => "0); REMOVE DATABASE x; --",
          "content" => "a chunk of text",
          "embedding" => [0.1, 0.2, 0.3]
        }
      ]

      assert {:error, %Error{code: :invalid_request, message: message}} =
               Veritas.Store.transaction(workspace, fn tx ->
                 Veritas.Store.upsert_chunks(tx, "subject_1", chunks)
               end)

      assert message =~ "chunk index"

      # Nothing was written, and the store is still there.
      assert [] = rows(workspace, :search_chunk)

      assert {:ok, _rows} =
               Veritas.Store.transaction(workspace, fn tx ->
                 Veritas.Store.list(tx, :ticket, %{where: [], order_by: []})
               end)
    end

    test "the sequence a change feed starts from is a number", %{workspace: workspace} do
      {:ok, _ticket} = Tickets.open(workspace, "incident", attrs("u1"), @actor)

      assert {:error, %Error{code: :invalid_request, message: message}} =
               Veritas.Store.transaction(workspace, fn tx ->
                 Veritas.Store.changes(tx, "0; REMOVE DATABASE x; --", [])
               end)

      assert message =~ "sequence"

      # The feed is intact, and the store is still there.
      assert {:ok, outbox} =
               Veritas.Store.transaction(workspace, fn tx ->
                 Veritas.Store.changes(tx, 0, [])
               end)

      assert outbox != []
    end
  end

  describe "the connection" do
    test "with no user is refused rather than made anonymously", %{workspace: workspace} do
      previous = Application.get_env(:veritas_core, :store)
      url = Veritas.Store.Surreal.settings()[:url]

      on_exit(fn -> Application.put_env(:veritas_core, :store, previous) end)

      Application.put_env(
        :veritas_core,
        :store,
        {Veritas.Store.Surreal, [url: url, user: nil, pass: "whatever"]}
      )

      assert {:error, %Error{code: :invalid_request, message: message}} =
               Veritas.Store.transaction(workspace, fn tx ->
                 Veritas.Store.list(tx, :ticket, %{where: [], order_by: []})
               end)

      assert message =~ "anonymously"
    end
  end
end
