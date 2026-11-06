defmodule Veritas.Core.Test.ParityProofRegistry do
  @moduledoc """
  Independently authored executable proof cases for docs/04:479-481.

  This registry is not generated from operations.json and contains no pass
  states. A registered case is only evidence after its exact ExUnit assertion
  has executed successfully. By-type cases do not certify other query modes,
  the shared filter grammar, or the entire ci.query operation.
  """

  @file_path "apps/veritas_web/test/veritas_web/parity_proof_test.exs"

  @doc "Returns the independently specified proof identifiers and exact test mappings."
  @spec cases() :: [map()]
  def cases do
    [
      %{
        id: "ci.query.by_type.cli",
        operation: "ci.query",
        surface: "cli",
        aspect_kind: "query_mode",
        aspect: "by_type",
        file: @file_path,
        test: "test ci.query.by_type.cli",
        mode: :mix
      },
      %{
        id: "ci.query.by_type.graphql",
        operation: "ci.query",
        surface: "graphql",
        aspect_kind: "query_mode",
        aspect: "by_type",
        file: @file_path,
        test: "test ci.query.by_type.graphql",
        mode: :mix
      },
      %{
        id: "ci.query.by_type.ui",
        operation: "ci.query",
        surface: "ui",
        aspect_kind: "query_mode",
        aspect: "by_type",
        file: @file_path,
        test: "test ci.query.by_type.ui",
        mode: :mix
      }
    ]
  end
end
