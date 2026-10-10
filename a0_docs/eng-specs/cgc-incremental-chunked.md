# cgc knowledge graph: incremental by default, chunked for giant repos (#888)

Status: implemented (cloud-infra `1_cicd/src/ops/cloud-cgc-db-chunk.sh`, wired into
`cloud-cgc-db-update.sh`). Test: `9_others/test/cgc-db-chunk-plan.test.sh`.

## 0. What was actually wrong (measured, not inferred)

Pipeline: `cgc-db.yml` → `cgc-db-index.yml` (phase `semantic`, then phase `graphrag`), one
matrix job per repo, each restoring `cgc-db-base` + `cgc-db-<repo>:latest`, running
`octocode index` (0.22.0) under a time slice, publishing the project dir back to
`cgc-db-<repo>:latest`; `restore-all` assembles every repo image on oci-apps; `reindex.sh`
there runs `octocode-export.py` → `kg-ingest.mjs` into kg-store.

kg-store on 2026-10-09: front 2022, cloud-infra 479, cloud-infra-desktop 121, front-data 29,
cloud-u-android 29 (of ~20,984 indexable), cloud-u-containers 11 (of ~3,470); cloud-data and
cloud-data-my-ai-memory absent.

Four defects, all read from octocode 0.22.0 source (`src/indexer/mod.rs`,
`differential_processor.rs`, `graphrag/builder.rs`, `store/metadata.rs`) and confirmed in run
logs:

1. **No durable progress without a completed run.** A file whose mtime moved but whose blocks
   are unchanged yields no embedding batch, so its `file_metadata` row only lands in the final
   flush of a run that *completes*. Timed-out runs record nothing for those files; the next run
   walks them again (they cost a `content_exists` query per block, ~20 files/min). Android:
   `Loaded metadata for 13594 files` (run 37685693199, Oct 7) → `13587` (run 37843203892,
   Oct 9); package 451M → 465M after 209 min. The "ratchet" did not ratchet.
2. **The graph pass only runs after the walk.** `index_files_with_quiet` collects
   `all_code_blocks` during the walk and calls `GraphBuilder::process_code_blocks` at the end.
   A walk killed by the slice never graphs anything (`#888` "storage but NO graphrag_nodes").
3. **The graphrag phase graphs only what it embeds.** It restores the semantic phase's image,
   whose `file_metadata` already covers the changed files, so every file mtime-skips and
   `all_code_blocks` is empty. Result: graphrag "success" runs that graph the 11 files that
   happened to change (cloud-u-containers), or, when the graph is empty,
   `build_from_existing_database`, which **clears** the graph and rebuilds every file in one
   go: not resumable, the 64–68% wall of forced runs.
4. **octocode's own commit marker.** `git_metadata` = HEAD makes octocode skip a run outright
   ("No commit changes since last index, skipping reindex"; the `0 of 0 files processed`
   no-op of 2026-09-15), or narrows it to octocode's own `git diff`.

Also relevant: `cleanup_deleted_files_optimized` (runs on every non-forced index) deletes every
indexed row whose path is missing **or matched by the ROOT `.gitignore`/`.noindex`**. The
walker additionally honours `.git/info/exclude`; the cleanup matcher does not.

## 1. Incremental by default

Unit of work = a **window** per run and phase:

    window = done ∪ dirty ∪ next_chunk(sorted(indexable − done) ∩ allowlist)

* `indexable` = `git ls-files` (gitlinks dropped) minus anything the root `.noindex` or git
  ignore sources match: exactly what octocode's walker can reach. Sorted `LC_ALL=C`, so the
  order is deterministic across runners (readdir order is not).
* `done` = files a **completed** octocode run processed in this phase. Only ever grows, except
  for files that left the tree.
* `dirty` = `git diff --name-only <seen> <HEAD>` ∩ done: changed since the last window.
  `seen` unresolvable (history rewritten) ⇒ every done file is dirty, which is cheap because
  unchanged files are a hashmap lookup in octocode's walk.
* Everything indexable **outside** the window goes into a delimited block in
  `.git/info/exclude`: hidden from the walk, invisible to the cleanup matcher, so indexed rows
  outside the window are **not** deleted. Never the root `.noindex` (it would delete them;
  the test's first mutation proves this).
* Before each window `storage/git_metadata.lance` is dropped (octocode reads a missing marker
  as "first-time git indexing" → full walk of the window with its per-file mtime check). The
  window, not octocode's marker, decides the work.
* **Deletions**: the file is missing → octocode's cleanup removes its blocks and graph nodes;
  the planner drops it from `done`/`dirty`. **Renames**: `--no-renames` diff = delete + add;
  the old path is cleaned up, the new path is todo.
* The manifest change gate (`.cgc-manifest-<phase>.json`, HEAD-only) now also requires the
  chunk state to be converged at that HEAD (`chunk_gate_current`), so a manifest written by
  a run that graphed 11 of 3,470 files cannot skip that repo forever.

Steady state for a converged repo: window = done ∪ dirty, `next` = the changed files; the
walk mtime-skips everything else in seconds.

## 2. Chunked first index / catch-up

* Chunks are the first `chunk` entries of the sorted remainder. Deterministic, recomputed
  every run, so files that appear mid-catch-up slot in without renumbering anything; "done"
  is recorded per **file**, not per chunk index, so no run ever redoes a completed window.
* State `<project>/.cgc-chunks-<phase>.json` (`seen`, `chunk`, `done[]`, `dirty[]`,
  `stale_runs`) lives **inside the project dir**, so it travels in the repo's own GHCR image
  with the DB it describes (same reason as the manifest, see `cgc-db-manifest-travels`).
* Within one job the loop plans → indexes → commits → publishes a checkpoint, then repeats
  while `remaining budget − measured publish time ≥ CGC_MIN_SLICE_MIN`. Every completed
  window is durable before the next starts; a run lands at least one chunk unless the chunk
  is too large, in which case:
* **Adaptive size**: timeout ⇒ halve (persisted in the state, so the next run is smaller);
  a window that used < ¼ of its slice ⇒ double; clamp `[min,max]`. Defaults semantic 3000,
  graphrag 1000, min 100, max 20000 (`.runtime.octocode.update.chunk.*` in build.json
  overrides; `CGC_CHUNK_FILES` pins it; `CGC_CHUNK=0` disables chunk mode).
* A timed-out window publishes like before (partial bytes, nothing marked done), so the
  embeddings it wrote still save time on the retry.
* Forced runs (indexer change) restart from base as before, but each completed window goes to
  `<repo>:latest-force-<phase>` with the resume marker, and the forced purge of graphrag
  tables is skipped when that partial was resumed. `:latest` is only replaced when the forced
  rebuild converges.

**Matrix fan-out of chunks: rejected.** octocode keys one project per origin URL (sparse slices
collapse into one project, measured 2026-09-03), and the store is LanceDB written by a single
octocode process: two jobs writing chunks of one repo produce two divergent table versions
of the same dataset, and merging them needs a Lance-level merge of `code_blocks`,
`file_metadata`, `graphrag_nodes` and `graphrag_relationships` that octocode does not offer.
Relationships are also discovered against the whole loaded graph, so separately built
sub-graphs miss cross-chunk edges. Parallelism stays at the repo level (the existing
8-wide matrix); a giant repo instead gets more chunks per run and more runs.

## 3. GraphRAG on top of the semantic index

* The graphrag window's `next` files get their mtime bumped by one second. octocode then
  processes them; for unchanged blocks `process_file_differential` **fetches the existing
  block** (no re-embedding) and pushes it to the graph builder. The builder loads the stored
  graph and skips any node whose content hash is unchanged, so only new or changed files
  cost LLM calls, and relationship discovery is scoped to processed nodes. A later semantic
  run restores the commit mtime, which is ≤ the stored one, so the bump never re-embeds.
* `build_from_existing_database` (clear-and-rebuild-everything) is never reached in steady
  state: it only fires when a run produced no blocks **and** the graph is empty; every
  graphrag window has blocks.
* **Never ahead of the embeddings**: graphrag chunk candidates are limited to the semantic
  state's `done` set (allowlist). A repo that converged in semantic before chunk mode existed
  has no semantic state and needs no allowlist.
* **LLM budget per run** is the chunk: at most `chunk` files of new LLM work (description +
  relationship calls, `openrouter:openai/gpt-4o-mini`), adapted by the same timing rule.
  Measured forced runs did ~2,200 cloud-u-containers files in a 240-min slice, so 1000 files
  leaves margin; dirty files are always included on top, and in steady state they are the
  whole cost.

### 3.1 Bounded LLM calls and time-capped graphrag windows (run 37929244331)

Window 1 of cloud-u-containers (1000 files) took 24 min; the chunk doubled to 2000 and
window 2 ran under `timeout <whole 204-min slice>`. It finished the description pass,
entered "AI analyzing 1681 files for architectural relationships" (211 sequential calls,
<= 7 s/call in window 1) and was still there when the slice expired; the loop then broke and
the job was gone. Three properties of octocode 0.22.0 / octolib 0.34.2 make that possible:

* no per-request timeout (`ChatCompletionParams::new` sets `request_timeout: None`), and
  OpenRouter keeps a slow non-streaming request open by dripping whitespace;
* relationships live in memory until the last relationship call returns: a killed window
  keeps its nodes and descriptions (persisted per batch) but **none** of its edges, and the
  next run skips those nodes as same-hash, so their edges are never computed;
* graphrag cost is not linear in the window: every already-done file that imports a symbol
  of the window is re-analysed, so windows get slower as `done` grows.

So: octocode's `OPENROUTER_API_URL` points at `cloud-cgc-llm-proxy.py` on 127.0.0.1, which
gives each attempt a hard wall-clock deadline (120 s), at most 3 attempts in 360 s per call,
honours Retry-After capped at 60 s, and answers a spent call with an outcome octocode
survives (relationship call: empty set; description call: 400, which octocode turns into a
deferral, and the planner keeps those paths outstanding). Five spent calls in a row open a
breaker; the window then finishes fast and the repo stops for the run. Each window prints one
LLM line (calls, failures by kind, Retry-After waited, latency p50/p95/max, s/file) and a
heartbeat every 10 min. A graphrag window plans at most 45 min of work at the measured rate, floored at 2500 ms/file (run 38044529950: a window of already-graphed files measured 360 ms/file, the next one 2342)
(the rate only decays halfway on a faster window) and is killed at 90 min whatever the slice;
a killed window halves the next one and the loop continues in the same job. Tests:
`cgc-db-llm-proxy.test.sh`, `cgc-db-graphrag-window.test.sh`.

## 4. Publishing partial progress safely

Decision: **additive partial graphs on `:latest` for normal runs; atomic swap for forced
rebuilds.**

* Normal runs only ever *add* files to `done` and graph nodes to the project dir: a chunk
  window cannot delete rows outside itself (exclude block, §1), so every published
  checkpoint is a superset of the last except for files really deleted upstream. Serving the
  growing graph is strictly better than serving the stale one, and restore-all/kg-ingest see a
  monotonically growing per-repo graph.
* Forced rebuilds start from base, so their partials are smaller than what is served; they go
  to the force tag and replace `:latest` in one publish when converged (§2).
* `kg-ingest.mjs`'s shrink guard (36632d96) stays as the backstop: a delta under 50% of the
  rows kg-store holds for a repo (≥ 50 rows) writes nothing.

## 5. Convergence monitor

Every chunked repo run emits one JSON record and a step-summary row:

    [cgc-db] CONVERGENCE {"repo":"cloud-u-android","phase":"semantic","head":"df0a7fd…",
      "seen":"…","total":20984,"done":6000,"remaining":14984,"dirty":0,"chunk":3000,
      "stale_runs":1,"converged":false}

The same record is written to `<project>/.cgc-status-<phase>.json`, so it is published in the
repo image and lands on oci-apps with restore-all (readable next to the DB it describes).
`stale_runs` counts consecutive runs that ended with work outstanding; at
`chunk.stale_alert_runs` (default 6, i.e. three days of twice-daily runs) the job emits an
`::error::` annotation naming the repo and its counts. kg-store's `file` count per repo is the
end-to-end check: it should approach `total` of the graphrag record.

## 6. Scheduling

* Per-repo matrix (max-parallel 8): a small repo's job finishes in minutes and never waits
  behind a giant inside its phase.
* Each job's budget is `CGC_BUDGET_MIN` (240) of a 315-min step; the chunk loop spends it
  window by window and reserves the measured publish time (default 40 min until measured).
* Coalescing: the orchestrator already cancels a scheduled run when a newer scheduled run
  waits, and restore-all queues on `ship-wg-runner`. Chunked progress is per file and durable
  per window, so cancelling a queued run never loses work.
* Known limit, unchanged here: `restore-all` and the graphrag phase wait for every semantic job,
  so a giant's last semantic window delays the small repos' publish by up to one slice.
  Splitting restore per repo is a follow-up, not needed for convergence.

## 7. Tests

`9_others/test/cgc-db-chunk-plan.test.sh` drives the real library on a scratch git repo
(window shape, exclude placement, monotonic done, dirty from diff, delete, rename, allowlist,
convergence, adaptation) and then re-runs the suite against seven mutated copies of the
library, each of which must fail.
