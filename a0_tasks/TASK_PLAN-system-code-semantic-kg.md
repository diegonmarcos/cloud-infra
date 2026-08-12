# TASK: System & Code Semantic Deep-Traversal Knowledge Graph (SCKG)

> **Implementer**: Sonnet. This is a multi-phase build that **extends** existing pieces — it does not replace them. Ship phases in order. Each phase ends with a tester.
> **Non-negotiable rules**: declarative, data-driven (`cloud-data-kg-schema.json`, `build.json`), engine-only, tests at every step.
> **Related tasks**: `TASK_PLAN-mail-semantic-graph.md` (mail corpus — a sibling that plugs into this graph as one domain).

---

## 0. Goal — in one sentence

Turn the full stack (code, configs, logs, metrics, deploys, mail, reports) into a **single traversable graph** whose edges are **typed predicates** (`CAUSED`, `BLOCKS`, `EMITTED_BY`, `REQUIRES`, …), so an agent can answer multi-hop causal questions by walking paths instead of matching keywords.

The canonical demo query (pass/fail at the end):
> *"The SMTP timeout in last night's log — what chain of code, config, env var, and deploy caused it, and who owns each link?"*

The agent must traverse **≥5 typed hops** (`LogEntry → EMITTED_BY → Function → READS → Config → BOUND_BY → EnvVar → SET_BY → Deploy → OWNED_BY → Person`) and synthesize a grounded answer — no hallucination.

## 1. What already exists (leverage, don't rebuild)

| Piece | File / Service | Status |
|---|---|---|
| **Schema (v1)** with 11 node types + 11 edge types | `cloud-data/cloud-data-kg-schema.json` | Good foundation — extend, don't replace |
| **Ingester** | `cloud-data/reports-logs/src/modules/kg_ingest.sh` | Already validates schema, rejects unknown types, redacts properties |
| **Staleness policy** | same schema file | 48h → stale, 30d → purge |
| **Octocode MCP (code side)** | `bc-obs_cloud-cgc-mcp` on oci-apps | Tools: `cgc_octocode_{search,graphrag,index}` |
| **Graph-shaped MCP stubs (future)** | same | `cgc_codegraph_{trace_call_path,impact_analysis,dependencies}` — **this plan implements them** |
| **Local LLM** | `ad-agi_ollama` (gcp-t4 GPU), `ad-agi_ollama-arm` (oci-apps-2 ARM fallback) | |
| **Agentic wrappers** | `ad-agi_rig-agentic-hai-1.5bq4`, `ad-agi_rig-agentic-sonn-14bq8` | |
| **Infra data sources** | `c3_topology`, `c3_configs`, `c3_deps`, `cloud-data-*.json` | Already normalized; feed the graph |
| **Reports / logs JSON** | `cloud-data-reports-logs.json`, `cloud-data-sec-scan.json`, `cloud-data-url-health.json` | Already structured; feed the graph |
| **Dagu scheduler** | on `oci-apps` | Use for nightly reindex DAGs |

**Nothing in this plan is "net new infra"**. Every phase extends a file or a service that already exists.

## 2. Gaps (what this task fills)

| Gap | Covered by |
|---|---|
| No semantic predicates beyond structural edges (`RUNS_ON`, `ROUTES_TO`) | Phase 1 — ontology v2 |
| No code-level nodes (`Function`, `Module`, `EnvVar`) | Phase 2 — code extraction |
| No runtime nodes (`LogEntry`, `Metric`, `Incident`, `Deploy`, `Person`) | Phase 3 — runtime extraction |
| No semantic enrichment (predicate assignment) | Phase 4 — LLM pass |
| Graph-query MCP tools are stubs | Phase 5 — `cgc_codegraph_*` implementation |
| No multi-hop causal query engine | Phase 6 — traversal API |

## 3. Architecture

```
┌─────────────────────  DATA SOURCES  ─────────────────────┐
│                                                          │
│  cloud/**/*.{nix,ts,rs,sh}  ─┐                           │
│  build.json * N              │                           │
│  compose.yml * N             ├─ Phase 2:                  │
│  cloud-data-*.json           │  Structural Extractor      │
│  Terraform HCL               │  (Octocode + parsers)      │
│                              │                           │
│  Docker logs (WG DAG pull)   ─┐                          │
│  journald (vm-pilot log ship)│                           │
│  Dagu run results            ├─ Phase 3:                  │
│  Health/URL reports          │  Runtime Extractor         │
│  GHA workflow runs           │  (reports-logs pipeline)   │
│  Sops/sec-scan findings      │                           │
│  Mail classifications (sibling task) ─┘                  │
│                                                          │
└───────────────────────────┬──────────────────────────────┘
                            │ raw nodes + structural edges
                            ▼
                ┌───────────────────────────────┐
                │  kg_ingest.sh (validates vs   │
                │  schema, redacts secrets)     │
                └──────────────┬────────────────┘
                               │
                               ▼
                ┌───────────────────────────────┐
                │  Graph store                  │
                │  (Octocode backend today;     │
                │  swap to FalkorDB if needed)  │
                └──────────────┬────────────────┘
                               │
                               ▼
                ┌───────────────────────────────┐
                │  Phase 4: Semantic Enricher   │
                │  LLM (Ollama/Haiku class)     │
                │  assigns predicate labels on  │
                │  candidate edges              │
                └──────────────┬────────────────┘
                               │
                               ▼
                ┌───────────────────────────────┐
                │  Phase 5–6: MCP query layer   │
                │  cgc_codegraph_trace_call_path│
                │  cgc_codegraph_impact_analysis│
                │  cgc_codegraph_dependencies   │
                │  sckg_causal_chain (new)      │
                │  sckg_blast_radius (new)      │
                └───────────────────────────────┘
```

---

## 4. Phases

### PHASE 1 — Ontology v2 (extend `cloud-data-kg-schema.json`)

Add node types for code + runtime + people, and semantic edge predicates. Every new entry lives in the existing schema file so `kg_ingest.sh`'s strict-reject behaviour protects the graph from drift.

**New node types** (key fields + minimal properties — properties list is the only thing allowed on the graph; nothing else passes through ingest):

```jsonc
"Function":    { "key": ["repo", "file", "symbol"],     "properties": ["language", "line_start", "line_end", "last_seen_ts"] },
"Module":      { "key": ["repo", "path"],               "properties": ["language", "last_seen_ts"] },
"EnvVar":      { "key": ["name", "scope"],              "properties": ["declared_in", "last_seen_ts"] },
"ConfigKey":   { "key": ["file", "path"],               "properties": ["type", "last_seen_ts"] },
"LogEntry":    { "key": ["source", "ts", "hash"],       "properties": ["level", "vm", "container", "last_seen_ts"] },
"Metric":      { "key": ["name", "labels_hash"],        "properties": ["unit", "last_seen_ts"] },
"Incident":    { "key": ["id"],                         "properties": ["severity", "started_at", "resolved_at", "last_seen_ts"] },
"Deploy":      { "key": ["service", "sha"],             "properties": ["workflow", "actor", "ts", "last_seen_ts"] },
"Person":      { "key": ["handle"],                     "properties": ["role", "last_seen_ts"] },
"MailThread":  { "key": ["thread_id"],                  "properties": ["subject_hash", "category", "urgency", "last_seen_ts"] }
```

**New semantic edge predicates** (additive — old edges keep working):

```jsonc
"CAUSED":       { "from": "Incident",    "to": ["Deploy", "Function", "ConfigKey", "EnvVar"] },
"BLOCKS":       { "from": "Incident",    "to": ["Service", "VM"] },
"EMITTED_BY":   { "from": "LogEntry",    "to": ["Function", "Container", "SystemdUnit"] },
"READS":        { "from": "Function",    "to": "ConfigKey" },
"BOUND_BY":     { "from": "ConfigKey",   "to": "EnvVar" },
"SET_BY":       { "from": "EnvVar",      "to": "Deploy" },
"REQUIRES":     { "from": ["Function","Service"], "to": ["ConfigKey","EnvVar","Service"] },
"OWNED_BY":     { "from": ["Service","Repo","Deploy"], "to": "Person" },
"DEFINED_IN":   { "from": "Function",    "to": "Module" },
"CALLS":        { "from": "Function",    "to": "Function" },
"REFERENCES":   { "from": "MailThread",  "to": ["Service","Person","Incident"] }
```

**Schema v2** — bump `"version": 2` and add a migration note. Ingester must treat unknown edges as hard-fail, unchanged.

**Tests — Phase 1**:
- **T1.1**: `jq -e '.version == 2' cloud-data-kg-schema.json`
- **T1.2**: `jq -e '.nodes | keys | length >= 21' cloud-data-kg-schema.json`
- **T1.3**: `jq -e '.edges | keys | length >= 22' cloud-data-kg-schema.json`
- **T1.4**: Run existing `kg_ingest.sh` dry-run on current reports-logs — must still pass (backward-compat).

### PHASE 2 — Structural Extractor (code, configs, topology)

Extend `bc-obs_cloud-cgc-mcp` to emit **nodes + edges** into the KG, not just a vector index.

Sources & mappings:

| Source | Node kinds emitted | Edge kinds emitted |
|---|---|---|
| Tree-sitter over cloud/, unix/, front/ repos | `Function`, `Module` | `DEFINED_IN`, `CALLS` |
| `build.json` scan across `a_solutions/` | `Service`, `EnvVar`, `ConfigKey` | `DECLARED_IN`, `REQUIRES`, `BOUND_BY` |
| `compose.yml` rendered | `Container`, `Image` | `RUNS_ON`, `BUILDS`, `MANAGED_BY` |
| `cloud-data-consolidated.json` + `c3_topology` | `VM`, `Service`, `Domain` | `RUNS_ON`, `ROUTES_TO`, `TERMINATES_AT` |
| Terraform HCL (GCP+OCI providers) | `VM`, `CloudflareRecord` | `AUTHORITATIVE_FOR` |
| `sec-scan` JSON | `SecretExposure` | `EXPOSES` |

**Data-driven mapping file** (new): `cloud-data/cloud-data-kg-sources.json` — declares for each source path which node/edge extractors apply. No source list hardcoded in code.

```jsonc
{
  "sources": [
    { "kind": "repo_ts",     "root": "/home/diego/git/cloud",  "extractors": ["tree-sitter-ts", "tree-sitter-nix"] },
    { "kind": "build_json",  "glob":  "a_solutions/*/build.json" },
    { "kind": "reports_json","glob":  "cloud-data/cloud-data-*.json" },
    { "kind": "terraform",   "root":  "b_infra/terraform" }
  ]
}
```

**Tests — Phase 2**:
- **T2.1**: After extractor run, total `Function` node count > 500 (real repos have thousands).
- **T2.2**: For a known function (pick `deriveHomeManager` in `cloud-data-config-derive.ts`), `cgc_codegraph_dependencies --symbol deriveHomeManager` returns ≥3 `CALLS` edges.
- **T2.3**: `c3_topology` JSON and graph VMs match 1:1 (sanity: no ghost nodes, no missing VMs).
- **T2.4**: Re-running extractor is idempotent — node count stable within ±0.5% (staleness TTL only).

### PHASE 3 — Runtime Extractor (logs, metrics, deploys, incidents, people)

Extend the existing `reports-logs/src/modules/kg_ingest.sh` pipeline with new collectors. Each collector is a small shell or Deno script that emits JSONL to stdin of `kg_ingest.sh`.

| Collector | Source | Nodes | Edges |
|---|---|---|---|
| `logs_docker.ts` | Docker logs over WG (already shipped for URL-health) | `LogEntry` | `EMITTED_BY` → `Container`, candidate `EMITTED_BY` → `Function` (regex-guided, LLM-refined in Phase 4) |
| `metrics_prom.ts` | Prometheus HTTP (if running) or the `obs_debug_metrics` MCP tool | `Metric` | — |
| `deploys_gha.ts` | `gh api repos/.../actions/runs` paged | `Deploy`, `Person` | `SET_BY`, `OWNED_BY` |
| `incidents.ts` | Mattermost alert channel scrape (via `mm_read`) | `Incident` | `BLOCKS`, `CAUSED` (candidate) |
| `mail_bridge.ts` | Sidecar corpus from `TASK_PLAN-mail-semantic-graph.md` | `MailThread` | `REFERENCES` |

All collectors write JSONL with a `last_seen_ts` field — the staleness machinery already handles decay.

**Tests — Phase 3**:
- **T3.1**: 24h after first run, `LogEntry` count > 100 and all have a parseable `source`.
- **T3.2**: Every `Deploy` in the last 7d maps to a real GHA run ID (no fabrications).
- **T3.3**: Redaction — `grep -rE 'ghp_|Bearer |-----BEGIN' graph_dump.jsonl` must return **zero** hits. The `properties` whitelist in the schema is enforced by `kg_ingest.sh` — prove it with a malicious test payload (insert a fake secret into a fixture log; confirm it is rejected or scrubbed).

### PHASE 4 — Semantic Enrichment (Haiku-class LLM assigns predicates)

Structural extraction produces **candidate** edges. The enrichment pass upgrades `MENTIONS` / `MAYBE_CAUSED` candidates to typed predicates from the schema.

Architecture:

1. A Dagu DAG `sckg-enrich.yaml` runs hourly.
2. For each candidate edge, the enricher builds a prompt containing the two endpoint nodes + their neighborhood + the schema's predicate list.
3. LLM returns one predicate (or `NONE` → drop the candidate).
4. Validator checks the predicate is allowed for the (from, to) kinds per schema. Unknown or illegal assignments are rejected.

**Declarative prompt templates** live in `cloud/a_solutions/bc-obs_cloud-cgc-mcp/src/templates/enrich-*.md`. The schema file is the single source of truth for allowed predicates — prompts render the list from it at build time, never hardcoded.

**Model choice**: default to Ollama `llama3.1:8b-instruct-q4` (cheap, local). Config in cgc-mcp's `build.json` lets you swap models without code changes. Benchmark table in the PR.

**Tests — Phase 4**:
- **T4.1**: On a synthetic fixture of 50 hand-labeled edges, enricher agrees with humans ≥80% (precision+recall ≥0.8). Fixture lives in `cloud/a0_tasks/fixtures/sckg-enrich-gold.json`.
- **T4.2**: Zero illegal predicates committed (schema-validator is a hard gate).
- **T4.3**: Idempotence — re-running enrichment on the same edges yields same predicates ≥95% (determinism check for the model+temperature=0 config).

### PHASE 5 — Implement `cgc_codegraph_*` MCP tools (no longer stubs)

Flesh out the three "future" tools in `bc-obs_cloud-cgc-mcp/src/` and add two new multi-hop tools:

| Tool | Inputs | Output | Max hops |
|---|---|---|---|
| `cgc_codegraph_dependencies` | `symbol` or `module` | tree of `DEFINED_IN`/`CALLS`/`REQUIRES` | configurable, default 3 |
| `cgc_codegraph_trace_call_path` | `from_symbol`, `to_symbol` | shortest path via `CALLS` | 10 |
| `cgc_codegraph_impact_analysis` | `symbol` | reverse-`CALLS` closure + touched services | 5 |
| `sckg_causal_chain` **(new)** | `incident_id` or `log_ts` + `level` | path: `LogEntry → Function → ConfigKey → EnvVar → Deploy → Person` | 8 |
| `sckg_blast_radius` **(new)** | `node_key` | set of downstream `BLOCKS`/`REQUIRES`/`DEPENDS_ON` reachable | 5 |

All tool schemas live in a single `tools.json` consumed by the MCP server — new tools require editing only that file + one handler.

**Tests — Phase 5**:
- **T5.1**: For a **manufactured incident** fixture (planted log + fake deploy + fake config change), `sckg_causal_chain` returns the exact 5-node chain injected, in order, at least 90% of runs.
- **T5.2**: `sckg_blast_radius(Service:caddy)` returns every other service with a `DEPENDS_ON`/`ROUTES_TO` path to Caddy. Compare against the declared list in `c3_deps` — must match exactly.
- **T5.3**: Performance: 95th-percentile tool latency < 500ms for 3-hop queries, < 2s for 8-hop.

### PHASE 6 — Agent interface & golden query

Wire the MCP tools into one of the `rig-agentic-*` services so a natural-language query drives a multi-hop traversal with grounded citations.

Flow:
1. User asks: *"Why did mail delivery slow down at 03:17 last night?"*
2. Agent calls `cgc_octocode_search --corpus=logs --query="slow mail delivery 03:17"` → gets `LogEntry` IDs.
3. Agent calls `sckg_causal_chain` on each.
4. Agent composes a narrative, **citing** each node by key (so the answer is fact-checkable).

**Tests — Phase 6**:
- **T6.1**: On the manufactured incident fixture, the agent's final answer must name the injected `Deploy.sha`, `ConfigKey.path`, and `EnvVar.name`. If any citation is missing → fail.
- **T6.2**: Against a **negative fixture** (no real cause planted), agent must respond "no causal chain found above confidence threshold" — NOT invent one.
- **T6.3**: User-facing transcript includes every node key it traversed (auditability). No black-box reasoning.

---

## 5. Non-goals

- This task does **not** replace Octocode's vector search — it layers graph traversal on top.
- Does not introduce a new graph DB unless Phase 5 perf tests fail (if Octocode's store maxes out at N hops, we evaluate FalkorDB/Neo4j then, not preemptively).
- Does not attempt automatic remediation — this is **read-only reasoning**. Action tools (restart, rebuild) stay in cloud-infra MCP behind human approval.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Schema sprawl — ad-hoc node/edge types creep in | `kg_ingest.sh` already rejects unknowns; keep version bump discipline, require a PR to edit the schema |
| LLM hallucinated predicates pollute graph | Hard schema validator after enrichment; T4.1 fixture prevents regressions |
| Secret leakage into nodes | Properties whitelist enforced by ingester; T3.3 proves with malicious fixture |
| Performance on deep queries | T5.3 caps latency; index bottlenecks → evaluate FalkorDB later |
| Agent hallucinates without graph backing | T6.2 forces "I don't know" on empty graph — refuses to invent |
| Corpus freshness lag | Dagu DAG cadence + `last_seen_ts` + stale-marking already part of schema |

## 7. Rollout

Phases 1-3 can ship without agent-facing consequences (graph just grows). Phase 4 runs offline (no SLA). Phase 5 is read-only new tools. Phase 6 is opt-in via a new MCP tool — no existing agent behavior changes.

Each phase gets its own PR; the tester in that phase is the merge gate.

## 8. Acceptance checklist

- [ ] Phase 1: schema v2 in place, backward-compat test green.
- [ ] Phase 2: structural nodes >500 for Function, extractor idempotent.
- [ ] Phase 3: log/deploy/incident nodes populating; redaction test green with malicious payload.
- [ ] Phase 4: enricher ≥0.8 precision/recall on gold fixture; schema validator rejects illegal predicates.
- [ ] Phase 5: three `cgc_codegraph_*` tools and two `sckg_*` tools implemented; fixture-based correctness tests green.
- [ ] Phase 6: agent passes positive + negative fixtures; every answer carries node-key citations.
- [ ] All new config data (sources, prompts, model choice, corpora) lives in JSON/MD files, zero hardcoded.
- [ ] No secrets or PII materialized in the graph (proven by fuzz-test).
- [ ] Every phase has a Dagu DAG or MCP entrypoint for re-runs — no "artisan" one-off scripts.

---

## 9. Open questions (answer in each phase's PR)

- Which tree-sitter grammars are already in the cgc-mcp image? If missing, add declaratively via the Dockerfile.
- Do we keep Octocode's built-in store, or swap to FalkorDB once Phase 5 latency tests are available? (Don't pre-decide.)
- GDPR: `Person.handle` from GHA is a GitHub login, but emails in `MailThread` may contain PII. Keep `Person.email` off the graph; store only hashed handles.
- Does the enrichment pass run centrally on oci-apps, or distributed across VMs? Start central; distribute later if throughput requires.

## 10. Implementer notes

- Absolute paths. `git -C /home/diego/git/cloud ...`.
- MCP-first for every VM check (`obs_debug_docker_exec`, `devops_workflows_dagu_trigger`). No raw ssh one-liners.
- Secrets: none expected in this pipeline; if one appears in a log, the ingest whitelist must drop the property — never commit a redaction list that implies the secret existed.
- Never edit `dist/` / deployed outputs — always source + `build.sh`.
- Every new tool goes into the existing MCP's `tools.json`; the plan does **not** create a new MCP service.
- Every new data source goes into `cloud-data-kg-sources.json`; the plan does **not** hardcode paths in extractors.
- First test of each phase is the **failing** test — write the assertion before the implementation.
