# Credo configuration for Veritas.
#
# Two rules shaped this file:
#
#   1. One owner per rule. The formatter owns whitespace; Credo must not be a
#      second implementation of the same check. Every check listed under
#      `disabled` below is either owned by `mix format` already, or is a style
#      choice this codebase makes deliberately.
#   2. Ratchet, don't rubber-stamp. Where a metric is a real signal but the
#      existing code already exceeds the default, the threshold is set to the
#      code's current worst value. New code that exceeds it fails; the
#      existing code does not drown the signal.
#
# Every finding this configuration absorbs is reported to the BEAM Engineer
# by file and line, so nothing is hidden by a threshold.
%{
  configs: [
    %{
      #
      # The name has to be "default" unless the run passes `-C <name>`.
      name: "default",
      #
      # Product code only. The applications under apps/ are the product;
      # their test suites belong to the SDET and are gated by the formatter
      # and by the test run, not by a linter.
      files: %{
        included: ["apps/*/lib/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      #
      # Strict mode adds the checks that are opt-in by default. The alias
      # `mix ci.lint` passes --strict as well; setting it here means a bare
      # `mix credo` is equally strict.
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        #
        # Checks that are switched off, each with the reason.
        disabled: [
          #
          # Owned by `mix format`. Credo re-implementing the formatter means
          # two tools disagreeing about the same line.
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          #
          # The codebase names nested modules in full on purpose. In a domain
          # this contract-heavy, `Veritas.Store.Surreal.config()` says more
          # than `Config.config()`, and the alias would have to be justified
          # on every use. This is a style decision, not an oversight.
          {Credo.Check.Design.AliasUsage, []}
        ],
        #
        # Checks added on top of Credo's defaults, and the metrics ratcheted
        # to what the code actually looks like today.
        extra: [
          #
          # The Adapter and the ticket state machine nest three to five
          # levels. The default limit of two flags every one of them; the
          # limit is set to the current worst case so that new code cannot
          # push it further. The five-deep case in
          # veritas_core/lib/veritas_core/tickets.ex is on the punch list.
          {Credo.Check.Refactor.Nesting, [max_nesting: 5]},
          #
          # Same reasoning: exhaustive `case` statements over SurrealDB
          # errors and ticket states read better than a dispatch table, and
          # they are what the current code does. The worst function today is
          # 15 (veritas/store/surreal.ex, query_error/3).
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
          #
          # `Veritas.Store.Memory.Server.walk/9` takes nine arguments. The
          # limit is ratcheted to that so a tenth argument fails.
          {Credo.Check.Refactor.FunctionArity, [max_arity: 9]}
        ]
      }
    }
  ]
}
