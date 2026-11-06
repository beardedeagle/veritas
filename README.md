# veritas

**A multi-OS, multi-distribution, multi-datacenter, agentic ITSM/ITIL/CMDB service with composable plugin capabilities.**

Veritas is a self-hosted service, not a tool. It owns the system of record for configuration items, the ticket lifecycle, the service catalog and SLA obligations (a service-level agreement is a promise about response and resolution time), knowledge, and the audit trail — and it extends through plugins rather than through a hardcoded feature list.

> **Status: the CMDB runs today; Incident is the only complete ticket lifecycle.** A four-app Phoenix umbrella serves a populated CMDB (Configuration Management Database — the factual record of what the organisation runs) with relation graphs, a blast-radius view, a CLI, a GraphQL API, an append-only audit trail and a plugin runtime. All five ticket types can be opened and transitioned; what only Incident has is the type-specific machinery around them. Local accounts with server-side sessions and role-based authorisation are in place, the release path is scripted and checked end to end ([`ops/`](ops/README.md)), and the design corpus is the project's normative record — the parts a reader needs are published below.

---

## Quick Start

Everything below runs on a clean checkout with **no environment variables**. The one step you do by hand is starting the datastore, and the reason is stated.

Every command here is a Mix task, and Mix finds an umbrella's tasks from the repository root — so they run from the root of the checkout, not from an application's directory. `bin/veritas-dev` is the same commands under one stable name, and it works from any directory:

```bash
bin/veritas-dev doctor
```

That is the **checkout's** entry point, and it runs a command. A **release's** `bin/veritas` is a different thing: it is the release's own start script — `start`, `stop`, `rpc`, `eval`, `remote` — because in a release the entry point is the product, not its build tasks. The two names are kept apart on purpose; see [`ops/README.md`](ops/README.md).

**You need:** Elixir 1.20.4 on Erlang/OTP 29 (pinned in [`.tool-versions`](.tool-versions)), and the `surreal` binary for the datastore. The binary has to be on your `PATH`, or named by `SURREAL_BIN`.

### 1. Get the dependencies and build the assets

```bash
mix setup
```

That fetches the dependencies and builds the CSS and JavaScript from `apps/veritas_web/assets/`. The built assets are not committed — they are build output, and committing them means committing something that is stale the moment a stylesheet changes — so this step is what makes the interface look like anything.

### 2. Start the app

```bash
mix phx.server
```

**There is no second thing to start.** Veritas starts and supervises its own datastore: the node launches `surreal` as a child process, waits for it to answer before it serves anything, and stops it when it stops. That is ADR-048 — an Architecture Decision Record, the numbered entry in the binding decision register — and it is the reason a clean checkout runs with nothing started by hand.

Leave it running. The steps below talk to the same datastore, from another shell.

The datastore's data directory, its port and its storage engine are all **defaults** — substitutable behind a named seam, not hard-coded:

| Decision | Default | Override |
|---|---|---|
| data directory | `<checkout>/var/surreal` | `VERITAS_DATA_DIR` |
| port | a free port | `VERITAS_SURREAL_PORT` |
| storage engine | `rocksdb` | `VERITAS_SURREAL_STORAGE` — `rocksdb`, `surrealkv` or `memory` |

To point Veritas at a datastore somebody else runs — a shared one, or one the operating system already looks after — set `VERITAS_SURREAL_URL` and the node leaves it alone.

### 3. Create the schema

```bash
mix veritas.cli migrate --workspace default
```

This applies the schema, the indexes and the seed rows, and prints:

```
schema applied to workspace default (version 5)
```

A **Workspace** is the boundary one team or one department works inside — every record belongs to one, and nothing crosses between them.

### 4. Seed a small CMDB to look at

```bash
mix veritas.cli ci seed --workspace default
```

That creates five configuration items — `db-01`, `web-01`, `web-02`, `app-01`, `svc-checkout` — and the relations between them. A **relation kind** is a typed, directed edge between two records: a configuration item to another, or a ticket to a configuration item. There are seven of them (`depends_on`, `parent_of`, `affects`, `implements`, `remediates`, `runs_on`, `provides`); the seed uses `depends_on`, `runs_on` and `provides`.

### 5. Make an account to sign in with

Veritas has no self-service sign-up: an operator makes the first account, and the first one is the break-glass path. It takes two commands, because making a privileged account has to prove the person asking is the person who owns the node.

```bash
# One: issue a token. It is written to a file with 0600 permissions and the
# path is printed — the token itself is not, because a terminal is one of the
# places a secret ends up.
mix veritas.cli account bootstrap-token --workspace default

# Two: make the account. The token is read from that file.
mix veritas.cli account create --workspace default \
  --email you@example.com --password '…' --role platform_admin
```

**The token is never taken on the command line.** A command line is readable by every process on the machine through the process list, so the token comes from the environment (`VERITAS_BOOTSTRAP_TOKEN`), from standard input (`--bootstrap-token-stdin`), from a file (`--bootstrap-token-file`), or from a masked prompt. The file the first command writes is the default source, which is why the second command needs no flag at all.

For the default Workspace, the delivery file is `~/.veritas/bootstrap-token.json.default.secret`. The base `bootstrap-token.json` is a legacy digest record; it does not contain the newly issued token. `--copy` requests a clipboard copy as well as the private file, and the command reports whether copying succeeded.

The role names are the corpus's own — `docs/02` is the normative set — and `mix veritas.cli account create` lists them when it refuses an unknown one.

**Every account after the first is made by an operator, not by a token.** The bootstrap path is one-shot: once the Workspace has an account, `account create` requires an operator identity from `--as` or `VERITAS_OPERATOR_EMAIL`. A second operator is made by an existing one:

```bash
export VERITAS_OPERATOR_EMAIL='you@example.com'
export VERITAS_OPERATOR_PASSWORD='…'

mix veritas.cli account create --workspace default \
  --email them@example.com --password '…' --role platform_admin
```

`VERITAS_OPERATOR_EMAIL` supplies the account for every command that accepts `--as`, including ticket transitions, account creation and password resets. An explicit `--as EMAIL` overrides it; blank environment values are ignored. The operator's own password comes from `VERITAS_OPERATOR_PASSWORD` and never from the command line, and the Policy decides whether that operator may perform the operation. A reset is never a bootstrap act: `account set-password` always authenticates an operator.

Then open **http://127.0.0.1:4000/cmdb/cis**. The CMDB list shows every configuration item with its relation count; clicking one shows its attributes and its **blast radius** — the set of things that depend on it, which is the question the CMDB exists to answer.

### Workflows, AI and plugin inspection

Open **Workflows** in the navigation to create a draft, edit its intake fields and steps, and publish it. Steps can collect manual answers, request an AI proposal, require approval, or capture after-action work. Branches select among the configured next steps. Publishing checks the ticket lifecycle; each new run keeps the published definition it started with, so later edits leave that run intact. Editing and publishing require an authorized human administrator.

The CLI uses the same service as the UI and GraphQL. With the operator credentials above set, a definition and intake can be submitted from JSON files:

```bash
bin/veritas-dev workflow save --file workflow.json
bin/veritas-dev workflow publish --id WORKFLOW_ID --revision 1
bin/veritas-dev workflow start --id WORKFLOW_ID --file intake.json
bin/veritas-dev workflow run --id TICKET_ID --json
```

The intake file contains `title`, optional `description`, and an `answers` object keyed by the configured field identifiers. A saved definition's current revision is required when updating or publishing it. `workflow generate --prompt '…'` can propose an editable definition through a configured provider. The generator supplies the supported field types and ticket transitions, checks the returned definition, and allows one correction attempt within the original request timeout. It returns an error if the corrected definition is still invalid. Review, save and publish a generated draft before use.

AI steps use the Workspace's provider configuration and credential reference. A blank model selection uses the step's configured model, then the provider's selection rules. Generating a proposal does not complete the step: an authorized human must review and explicitly approve it. Returning through a rework branch requires a fresh proposal and approval. Run data retains accepted output snapshots with model, provider, approver and visit provenance separately from the pending proposal. Recorded work shows the latest approved output for each step; earlier approvals remain in run data and the audit trail.

In **Admin**, Platform Admins and Auditors can inspect the current Workspace's installed plugins, requested and granted scopes, namespace, status and Host API version. The manifest form checks JSON structure and host compatibility without installing or starting a plugin. It does not verify signatures or provenance. Installation, grants and lifecycle management remain separate host operations.

### 6. Run the tests

Run each suite **from its own app directory**. This is a real trap: run `mix test` from the umbrella root with a path filter and it silently produces no output, which looks like a pass.

```bash
cd apps/veritas_core && mix test     # the domain, the store adapter and the audit chain
cd ../veritas_web   && mix test       # the LiveView shell and the CMDB screens
cd ../veritas_plugin && mix test      # the plugin runtime
```

### Optional: a datastore somewhere else

The defaults are `http://127.0.0.1:8000`, user `root`, password `root`. If your store is elsewhere, set `VERITAS_SURREAL_URL`, `VERITAS_SURREAL_USER` and `VERITAS_SURREAL_PASS`. **In production the password has no default** — the service refuses to start without one, and says so.

### The release

The steps above run a checkout. A **release** is a directory that carries the node, the ERTS, and the datastore binary it was verified against — nothing for the host to install but the directory itself.

- [`ops/README.md`](ops/README.md) — what a release contains and where each piece comes from.
- [`ops/install.sh`](ops/install.sh) — unpacks a release tarball, creates the service account, and checks the datastore binary's SHA-256 against the digest pinned for it before it uses it.
- [`ops/RUNBOOK.md`](ops/RUNBOOK.md) — the operator's book: starting it on a clean host, running it as a service under `systemd` or `launchd`, telling that it is working, backing it up, and what to do when it will not start.

The release's own entry point is `bin/veritas` **inside the release directory**, and it starts the node — `start`, `stop`, `rpc`, `eval`, `remote` — because in a release the entry point is the product rather than its build tasks. Which role it runs as is named by `VERITAS_ROLE`, not by the command: the same release is the server, the scheduler or the agent.

---

## The product in one line

**The CMDB is the spine. Everything else is a query over it.**

Incident, Change, Problem, Vulnerability, SLA and Knowledge are queries and workflows over configuration data. Everything beyond that spine arrives through plugins, never through a fork of the core.

## One discipline, three altitudes

ITSM, ITIL and CMDB are not three modules — they are one discipline seen from three angles, and Veritas implements them as one system.

| Altitude | What it is | What Veritas owes it |
|---|---|---|
| **ITSM** | The discipline: designing, delivering, supporting and improving services to meet organisational need. Framed by ISO/IEC 20000, not confined to it. | Veritas *is* an ITSM system. Every capability is judged by whether it serves the discipline. |
| **ITIL 4** | The guidance framework for that discipline — values, guiding principles and 34 practices. | Veritas implements the practices as the discipline needs them. It is not "ITIL 4 software" and claims no certification; the mapping is documented and auditable. |
| **CMDB / configuration management** | The enabling practice that supplies the factual substrate — CIs, relationships, ownership, state. | The CMDB is the spine. Every other capability is a query over configuration data. |

They ship together. CMDB without practices is a spreadsheet; practices without CMDB are a queue; ITIL 4 without ITSM is a document library.

## The stack

This is the architecture the corpus commits to. The section below says how much of it runs today.

| Layer | Choice |
|---|---|
| Language | Elixir 1.20.4 on Erlang/OTP |
| Web | Phoenix + LiveView — LiveView-first, no SPA |
| API | Absinthe (the Elixir GraphQL library) plus a first-class CLI, both over one service layer |
| Data | SurrealDB — the only system of record. Graph, key-value, time-series, vector and full-text in one engine |
| Clustering | Native Erlang distribution (`epmd`, the Erlang port mapper daemon, plus `:net_kernel`, the node's distribution server) — fully connected inside a Datacenter, never across the WAN |
| Packaging | Native `mix release` for Linux (systemd, `.deb`, `.rpm`, Alpine), macOS (launchd, Homebrew), Windows (service, Scoop), Nix and containers |
| Agentic | LLM (large language model) agents are first-class actors; every consequential action passes a durable human approval gate and is audited |
| Extensibility | Plugins are composable capabilities — manifest-declared, capability-scoped, sandboxed, hot-pluggable |

## Two audiences, one binary

**Home-lab operator** — one binary, no licence cost, no infrastructure team, dense CLI-first tooling, runs on a laptop.

**Enterprise IT** — SSO (single sign-on, one identity across the estate), RBAC (role-based access control, permissions attached to a role rather than to a person), append-only audit, SLA obligations, approval workflows, high availability across Datacentors, procurement-grade evidence.

These are two readings of the same product, not two products. There is no edition split, no feature gate and no paid tier: whatever an enterprise deployment needs, the home-lab binary already contains. What that enterprise deployment still has to *supply* — an identity provider, a second Datacenter, the operator's own support contract — is the enterprise prerequisite, and until it is supplied the corresponding capability stays dormant rather than absent.

## Free forever

**No enterprise edition, no feature gate, no per-seat or per-node metering, no paid plugin tier, no paid marketplace listing.** The only cost Veritas can ever produce is cloud hosting — outside the project's control and outside its promise.

The binding rule: **no commercial dependency for any required capability.** The free SurrealDB edition and only the free edition. Local accounts plus free OSS identity providers — OIDC and SAML (OpenID Connect and SAML, the two protocols an identity provider speaks) are protocols, not products. Self-hosted models by default, or a provider the operator already pays for with their own key. A build, test and scan path that runs entirely on free tooling.

Enterprise features ship in the same free binary. What an enterprise buys is support and engineering time, never a licence.

The named anti-pattern: metered agent actions, per-seat tiers, or a "community edition" that is the real product with the legs cut off. Veritas keeps token and cost accounting in the schema so the *operator* can see and control their own spend — never so a vendor can bill for it.

## No lock-in

The agentic framework sits behind a narrow host-owned **Port**. A Port is the seam a subsystem talks through: the domain states what it needs, an adapter supplies it, and the domain depends on the contract and nothing else. Adapters implement the Port; the agent loop, the tool registry and the approval state belong to the host — because an approval gate that lives in a framework callback cannot outlive a process restart.

The same discipline applies to the datastore: the official SurrealDB client embeds a Rust NIF (a native library compiled into the BEAM's port) that breaks the Alpine, Windows and Nix build matrix, so Veritas owns a thin HTTP client instead.

## What is built

- **The CMDB.** Configuration items — the things the organisation runs — with a type registry, typed relations between them, a list and a detail screen, and a blast-radius calculation that walks the dependency graph. The Overview dashboard reads the real CMDB, not fixture data.
- **All five ticket types work, but only Incident is complete end to end.** A Change, a Problem, a Vulnerability and a Service Request can all be opened, listed, viewed, transitioned and audited today: the lifecycle edges are seeded data, and the domain is generic over the type. What is not built is the type-specific machinery around them — the approval-bearing transitions, the post-implementation review, the SLA clock and the type-specific detail records.
- **An append-only Audit Log** with a keyed hash chain — each record carries a hash of itself and of the one before it, so a removed or edited record is detectable. The key lives in a key ring on the operator's machine.
- **Three surfaces over one service layer**: the LiveView UI, a GraphQL API, and a CLI. Every operation in the UI is available in the other two.
- **A plugin runtime.** A plugin is a capability that runs as its own operating-system process and speaks JSON-RPC (a request/response protocol that carries method calls as JSON objects) over a local socket; the host checks every call against the capabilities the plugin's manifest declared.
- **A store abstraction** with a conformance suite, so the datastore can be substituted without touching the domain.
- **A benchmark harness** at [`bench/`](bench/) that measures the hot paths and reads the plan the store actually chose, so a query that regresses from an index scan to a table scan fails the build. **The committed baseline it compares a run against is not recorded yet**, so the regression rules stay inert until an operator records one on their own reference machine; until then a gated run reports a no-baseline result rather than a pass.

### What is not built yet

Stated plainly, because a README that hides a limitation is worse than one that names it.

- **All five ticket types can be opened and transitioned**; the lifecycles are seeded data and the domain is generic over the type. What only Incident has is the type-specific machinery: the approval-bearing transitions, the post-implementation review, the SLA clock and the type-specific detail records.
- **Local accounts are the only identity.** Passwords are hashed with Argon2id, sessions are server-side, and every request is authorised against the corpus's role matrix — but OIDC, SAML, LDAP, SCIM, MFA and API tokens are specified in the corpus and not built. The port is shaped so that each is an Adapter rather than a change to the domain.
- **`mix release` has never been executed.** There is no release artefact, the per-platform `surreal` binary is not bundled yet, and there is no verified install path.
- **The agentic layer is deliberately not in the default build.** The Port is defined and the adapters are the seam, but no agent framework ships.
- **No durability or availability figures are published.** The design corpus sets budgets; those are budgets, not measurements, and the project publishes no RPO, RTO or SLA it has not measured and reproduced.

## The design corpus

The design corpus is the project's **normative** record: where the code and a document disagree, the corpus wins and the code is the defect. It is the team's working material — the decision register, the data model, the security architecture, the performance budget — and it is **not committed to this repository**. The documents below are the ones a reader, a contributor or a fork needs, and they are published.

| Document | What it is |
|---|---|
| [GOVERNANCE.md](GOVERNANCE.md) | The commitments: Apache-2.0, free forever and never sold, the mark, inbound contributions, and what is deliberately not settled |
| [TRADEMARK.md](TRADEMARK.md) | The trademark policy: what the mark covers, what a fork must do, and how a request or an objection is handled |
| [Plain-Language Glossary](docs/31-plain-language-glossary.md) | Every term the project uses, explained |
| [Architecture at a Glance](docs/18-architecture-at-a-glance.md) | The system on one page |

Open the **[visual design map](docs/veritas-at-a-glance.html)** for the one-page version of the system.

## Project wiki

The llm-wiki at `~/Documents/vaults/veritas` holds the rationale, the decision history, the open questions and the project Kanban board. Design work is not complete until it is reflected there.

## Licence

**Apache-2.0**, with a project trademark policy. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The code may be forked, redistributed and sold freely. **The Veritas name and logo are not licensed** — Apache-2.0 section 6 grants no trademark rights, and no distribution may present itself as Veritas, Veritas Enterprise, Veritas Cloud or any confusingly similar mark.

Veritas itself is free, for life, and will not be sold — not by the project, and not by anyone else. See [GOVERNANCE.md](GOVERNANCE.md) for the governance that makes that hold, and [TRADEMARK.md](TRADEMARK.md) for the mark's rules.

The one thing a fork may not do is call itself Veritas.
