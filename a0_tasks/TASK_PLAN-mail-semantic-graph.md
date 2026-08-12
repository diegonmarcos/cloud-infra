# TASK: Mail Semantic Deep-Traversal Knowledge Graph (Stalwart × Ollama × Octocode)

> **Implementer**: Sonnet. This is a multi-phase research-then-build. Phase 1 must prove the Sieve↔Ollama loop works before Phase 2 builds the corpus; Phase 3/4 depend on Phase 2.
> **Non-negotiable rules**: declarative, data-driven (`build.json`, cloud-data JSONs), engine-only deploys, test after every phase.
> **Dependency**: Phase A of `TASK_PLAN-mail-wg-only.md` should ship first — this plan assumes Stalwart listeners already bind to the WG address.

---

## 0. Goal

Turn the Stalwart mail store into a queryable semantic graph so an AI agent can answer questions like:

> *"Emails from anyone in the 'Marketing' entity who is waiting for a 'Contract' signature."*
> *"Find the person who mentioned the budget last Tuesday and show every thread they're in."*
> *"What's the most overdue reply in my inbox?"*

Mechanism: mail lands → Stalwart Sieve pipes it to Ollama → LLM returns structured JSON (entities, category, urgency, project) → JSON is stored as Markdown sidecar → Octocode (cgc-mcp) indexes the corpus → agents query via the existing MCP tools (`cgc_octocode_search`, `cgc_octocode_graphrag`).

## 1. Ground truth (verified)

| Component | Service (cloud/) | Deploy target | Notes |
|---|---|---|---|
| Mail MTA | `aa-sui_tools-stalwart` | oci-mail | Stalwart v0.13, config rendered from `src/templates/config.toml.tpl` |
| Mail MTA (primary) | `aa-sui_tools-maddy` | oci-mail | Maddy is the inbound truth today; Stalwart runs in shadow mode |
| Mail MCP (JMAP client for agents) | `aa-sui_mail-mcp` | oci-apps | Multi-account (Maddy + Stalwart + Resend) per MEMORY.md |
| LLM inference | `ad-agi_ollama` | gcp-t4 (GPU) | primary |
| LLM inference (fallback) | `ad-agi_ollama-arm` | oci-apps-2 | ARM fallback |
| Code-graph / Octocode MCP | `bc-obs_cloud-cgc-mcp` | oci-apps | Tools: `cgc_octocode_search`, `cgc_octocode_graphrag`, `cgc_octocode_index` |
| Octocode vector DB | — | oci-apps (named volume) | per MEMORY.md "Octocode vector DB migration" |
| Stalwart scripts dir | `aa-sui_tools-stalwart/src/code/` *(if present, else create)* | — | |

## 2. Architecture

```
                  ┌─────────────┐    inbound MX
   External MTA ─→│  Maddy :25  │─────────────────┐
                  └─────────────┘                 │
                                                  │  smtp-proxy
                                                  ▼
                                          ┌──────────────┐
                                          │ Stalwart     │  Sieve fires on delivery
                                          │ (shadow now, │
                                          │  primary     │  ┌────────────────────────┐
                                          │  later)      │─→│ Sieve: llm_prompt(...) │
                                          └──────────────┘  └───────────┬────────────┘
                                                                        │ HTTP
                                                          ┌─────────────▼──────────────┐
                                                          │  Ollama /v1/chat           │
                                                          │  (gcp-t4 or oci-apps-2)    │
                                                          └─────────────┬──────────────┘
                                                 JSON {entities,category,urgency,project}
                                                                        │
                                              ┌─────────────────────────▼─────────────────────────┐
                                              │  mail-graph-sidecar writer (new small service)    │
                                              │  Writes /opt/mail-graph/YYYY-MM-DD/<msgid>.md     │
                                              │  (body + front-matter JSON)                       │
                                              └─────────────────────────┬─────────────────────────┘
                                                                        │  (shared volume)
                                                                        ▼
                                                          ┌──────────────────────────────┐
                                                          │  cloud-cgc-mcp (oci-apps)    │
                                                          │  cgc_octocode_index nightly  │
                                                          │  cgc_octocode_graphrag query │
                                                          └─────────────────────────────┘
```

## 3. Upstream feasibility — MUST verify before Phase 1 starts

The user's suggested Stalwart TOML snippet (`[ai.models.email-classifier]`, `[remote.ollama]`) and Sieve invocation (`${llm_prompt('email-classifier', ...)}`) are **plausible but NOT confirmed** against current Stalwart docs. Sonnet must:

1. Read https://stalw.art/docs/ for AI integration — locate the actual section name, exact config keys, exact Sieve extension namespace and function signature.
2. Read https://stalw.art/docs/sieve/extensions/expressions/ (or equivalent) for `vnd.stalwart.expressions` feature flags.
3. Confirm Stalwart v0.13 (the pinned version) supports LLM calls — if it's v0.14+ only, bump the pin first via `build.json`.
4. If Sieve-native LLM call is **not** available, design the fallback: Stalwart Sieve → `mailto_external` or an exec pipe → small local HTTP service (Python/Deno) → Ollama → writes sidecar. The plan downstream is identical; only the glue changes.

**Deliverable from this step**: a short `PREWORK.md` in the task folder documenting exactly which Stalwart config keys and which Sieve functions are used, with upstream doc URLs.

---

## 4. Data model (declarative, in `build.json`)

### 4.1 `aa-sui_tools-stalwart/build.json` — new `ai_pipeline` section
```jsonc
"ai_pipeline": {
  "enabled": true,
  "provider": {
    "name": "ollama",
    "upstream": "http://ollama.app:11434/v1/chat/completions",
    "model": "llama3.1:8b-instruct-q4",
    "timeout_seconds": 30
  },
  "classifier": {
    "system_prompt_file": "templates/prompts/email-classifier.md",
    "json_schema_file": "templates/prompts/email-classifier.schema.json",
    "max_tokens": 512
  },
  "sidecar": {
    "volume": "mail_graph_sidecar",
    "path": "/opt/mail-graph",
    "format": "markdown",
    "frontmatter": "yaml"
  }
}
```

Values are consumed by the flake to substitute `@AI_*@` tokens in `config.toml.tpl` and the Sieve script template. Zero literals in templates.

### 4.2 `bc-obs_cloud-cgc-mcp/build.json` — extend with a corpus mount
```jsonc
"corpora": [
  { "name": "code",  "path": "/opt/code-repos",   "kind": "code",     "reindex_cron": "0 3 * * *" },
  { "name": "mail",  "path": "/opt/mail-graph",   "kind": "markdown", "reindex_cron": "0 4 * * *" }
]
```
The existing `cgc_octocode_index` tool gains a `corpus` arg that selects which mount to scan. Reindex is driven by Dagu DAG (see MEMORY.md "Octocode vector DB migration"), never a raw cron on the VM.

### 4.3 Shared volume
A named Docker volume `mail_graph_sidecar` is mounted by **both** the Stalwart container on oci-mail **and** the cgc-mcp container on oci-apps. Since they're on different VMs, use rsync-over-WG (Dagu job every 5 min) or — cleaner — have the sidecar writer push via the existing `vm-pilot` `ssh_run` mechanism to oci-apps' `/opt/mail-graph`. Decide in Phase 2.

---

## 5. Phases

### PHASE 1 — Sieve → Ollama round-trip (proof of concept)

**Scope**: a single test email arriving at Stalwart fires Sieve, reaches Ollama, returns JSON, logs are visible. No indexing yet.

Steps:
1. Complete § 3 pre-work (`PREWORK.md`).
2. Add `ai_pipeline` block to `aa-sui_tools-stalwart/build.json` (§ 4.1).
3. Create `src/templates/prompts/email-classifier.md` (system prompt) and `.schema.json` (expected JSON shape).
4. Extend `src/templates/config.toml.tpl` with the verified Stalwart AI config keys, using `@AI_*@` substitutions.
5. Extend the Sieve script (`src/code/filter.sieve` or wherever currently lives — verify) to call the classifier and log the result via `setflag` or `vnd.stalwart.log`.
6. Ensure Ollama is reachable from oci-mail — add a `wg0` route to gcp-t4:11434 if not already (MCP `obs_debug_docker_exec` on oci-mail to curl the endpoint).
7. Ship stalwart: `cd aa-sui_tools-tools-stalwart && ./build.sh ship`.
8. Send a test email to a Stalwart-routed address. Confirm via Stalwart logs the LLM was called and returned valid JSON.

**Tests — Phase 1**:
- **T1.1**: `jq -e '.ai_pipeline.provider.upstream' dist/build.json | grep -q 11434` (config wired).
- **T1.2**: `curl -sS http://ollama.app:11434/v1/models` from oci-mail via MCP exec → list contains the pinned model. Fails fast if WG routing to gcp-t4 broken.
- **T1.3**: Inject a synthetic email via `mail-mcp`'s `mail_send` tool. Within 10s the Stalwart log must show `[sieve] llm classification: {…valid JSON…}` and the schema validates against the schema file.
- **T1.4**: Timeout path: stop gcp-t4's Ollama (via MCP `devops_service_stop`); send another test email; log must show `llm timeout, fallback=no-op` and delivery must **not** block (mail still lands in inbox).

### PHASE 2 — Sidecar writer + shared corpus

**Scope**: every delivered mail produces `<date>/<msgid>.md` with YAML frontmatter containing the JSON classification and the body in plaintext markdown. Corpus reachable from oci-apps.

Steps:
1. New micro-service `aa-sui_mail-graph-writer` (Rust or Python — lean toward Python for speed of iteration). Single endpoint: `POST /ingest` { msg_id, body, classification }. Writes to the named volume.
2. Sieve calls this endpoint after classification (via an HTTP sieve extension or via the bridge from § 3 fallback).
3. Corpus distribution — pick ONE of:
   - **2a. Rsync-over-WG** Dagu DAG (5-min cadence), source `oci-mail:/opt/mail-graph`, dest `oci-apps:/opt/mail-graph`. Simple, declarative via Dagu.
   - **2b. NFS on WG** — Mount `oci-apps:/opt/mail-graph` from oci-mail. Adds NFS server to infra (complex).
   - **2c. Direct write from writer** — writer posts each file to a small receiver on oci-apps via WG. Same as 2a but pushed vs pulled.
   Recommend 2a for declarative simplicity.
4. Format each file as:
   ```markdown
   ---
   msg_id: <...>
   date: 2026-04-22T10:15:00Z
   from: someone@example.com
   to: me@diegonmarcos.com
   subject: …
   classification:
     category: work
     project: ProjectX
     urgency: high
     entities: [PersonA, ContractZ, 2026-05-01]
     sentiment: neutral
   ---
   <plaintext body>
   ```

**Tests — Phase 2**:
- **T2.1**: Send 10 synthetic emails; count files in `oci-apps:/opt/mail-graph/` (via MCP exec) = 10 within 5-min SLA.
- **T2.2**: Frontmatter YAML must parse (`python -c 'import yaml,glob; [yaml.safe_load(open(f).read().split("---")[1]) for f in glob.glob("/opt/mail-graph/**/*.md")]'` in a Dagu test step).
- **T2.3**: All files match schema at `templates/prompts/email-classifier.schema.json`.

### PHASE 3 — Index with Octocode / cgc-mcp

**Scope**: `cgc_octocode_index` knows about the `mail` corpus and indexes it nightly; `cgc_octocode_graphrag` can answer semantic queries over it.

Steps:
1. Extend `bc-obs_cloud-cgc-mcp/build.json` per § 4.2 with `corpora[]`.
2. Refactor the MCP tool `cgc_octocode_index` to accept `corpus` parameter (default = all corpora, or specific). Respect declared `kind` — markdown corpora use a different chunker than code.
3. Add Dagu DAG `mail-graph-reindex.yaml` that runs `cgc_octocode_index --corpus=mail` every night at 04:00 UTC, and on-demand via MCP `mcp__cloud-infra__devops_workflows_dagu_trigger`.
4. Verify graphrag can traverse across mail and code corpora (cross-corpus entity links — e.g., email mentions "issue #42" and graph links to the repo's issue).

**Tests — Phase 3**:
- **T3.1**: After Dagu run, `cgc_octocode_search --corpus=mail --query="ProjectX"` returns at least one of the 10 synthetic emails.
- **T3.2**: `cgc_octocode_graphrag --query="emails from people mentioning ContractZ"` returns the synthetic emails containing "ContractZ" entity.
- **T3.3**: Reindex idempotency — running twice in a row does not duplicate nodes (`graphrag overview` node count stable).
- **T3.4**: Corpus isolation — searching `--corpus=code` for a mail-only entity returns zero hits (no cross-corpus bleed).

### PHASE 4 — Agent-facing "Smart Folders"

**Scope**: virtual mailbox views powered by queries, exposed through `mail-mcp` or a new MCP tool.

Steps:
1. Add `mail-mcp` tool `mail_smart_folder_query` that takes a natural-language query, routes it to `cgc_octocode_graphrag`, returns JMAP mailbox-shaped results (list of msg IDs with metadata).
2. Optional: Stalwart-side virtual mailbox — use Stalwart search-based mailbox feature (verify availability) that exposes a static filter like `@ai.keyword("ProjectX")`. Purely a client-convenience layer; independent of the graph.
3. Document three example queries in `docs/mail-smart-folders.md`:
   - "Unreplied threads from the last 7 days"
   - "Anyone waiting for a signature"
   - "Everything tagged ProjectX"

**Tests — Phase 4**:
- **T4.1**: `mail_smart_folder_query` returns correct IDs for each of the three example queries, compared against a hand-curated ground-truth list over the synthetic corpus.
- **T4.2**: Latency <3s p95 over a 10k-email corpus (synthetic load-gen in the test).
- **T4.3**: Privacy — the MCP tool must not leak raw email bodies to the agent unless explicitly requested (default = metadata only).

---

## 6. Open questions (answer in the PR description before merging each phase)

- Which Ollama model is the best cost/quality for classification? Start with `llama3.1:8b-instruct-q4`; benchmark against `mistral-nemo` on the synthetic test set.
- Does Stalwart's native Sieve LLM extension exist in the pinned version, or do we bridge via a local HTTP side-service (§ 3)?
- Corpus distribution: rsync-over-WG (2a) vs NFS (2b) vs push (2c). Recommend 2a, justify in PR.
- Stalwart promotion: when does Stalwart stop being shadow and become primary? This task does NOT require that promotion — the graph works even if only Stalwart-shadow sees the mail. But if Stalwart stays shadow forever, the pipeline should also apply to Maddy-delivered mail; consider a symmetrical Maddy-side hook.
- GDPR / privacy: do we want a redaction pass before the sidecar is written (scrub bodies below a confidence threshold, keep metadata only)?

## 7. Non-goals

- This task does not replace `mail-mcp` or change JMAP behavior.
- No new public endpoints.
- No change to outbound mail.
- No change to the WG topology (Phase B of the mail-wg-only task is orthogonal).

## 8. Risks

- **LLM halluciations** corrupt the graph. Mitigation: strict JSON schema + re-ask on parse failure; log low-confidence outputs and skip indexing.
- **Ollama unavailable** blocks delivery if pipeline is synchronous. Mitigation: make it async — Sieve fires-and-forgets, classification runs in a worker queue; mail delivery never blocks.
- **Storage creep** — 10k emails × 4KB sidecar = 40MB (fine). 1M emails = 4GB (still fine). Put the volume on the larger oci-apps disk.
- **Model drift** — entities extracted this month may not match next month's taxonomy. Mitigation: normalize entities to a canonical list maintained in `cloud-data-mail-taxonomy.json`, driven by build.json.

## 9. Acceptance (all phases)

- [ ] Phase 1: Sieve log shows classification JSON on every test email.
- [ ] Phase 2: 100% of delivered test mail has a sidecar file in the corpus.
- [ ] Phase 3: graphrag queries return correct mail IDs; nightly reindex is a Dagu DAG.
- [ ] Phase 4: three example queries work via `mail_smart_folder_query`.
- [ ] No raw secrets or API keys in any committed file.
- [ ] All new config keys live in `build.json`; templates contain only `@TOKEN@` substitutions.
- [ ] Rollback: `ai_pipeline.enabled = false` in build.json + redeploy = system returns to pre-task behaviour; no orphaned state on the VMs.

---

## 10. Implementer notes

- Absolute paths. `git -C /home/diego/git/cloud ...`.
- Use MCP tools for all VM-side checks (`obs_debug_docker_exec`, `devops_ssh_check`, `devops_workflows_dagu_trigger`). No raw ssh one-liners.
- Secrets (Ollama API key if ever needed, NFS creds, etc.): sops pipeline only.
- Never commit submodule paths; use the auto-sync GHA.
- Never run `nix-env`, `docker compose up`, or edit `/etc/` on a VM. Engine or nothing.
- Start Phase 1 with a **failing test first**: write the synthetic email injector and assert log content before the implementation exists.
