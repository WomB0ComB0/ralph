# Ralph memory → Synapse bridge — design

**Date:** 2026-08-01
**Status:** approved (design)
**Owner:** ralph

## Problem

Ralph's compounding memory — verified skills and mined failure themes — lives in
local `.ralph/state/*` JSON, per-repo. Nothing is shared across repos, and Synapse
(the org-brain retrieval service ralph already health-checks every patrol tick) is
used only as a liveness/context probe, never as ralph's actual memory substrate.

Consequences:
- A lesson learned patrolling `resq-software/npm` cannot inform `resq-software/crates`.
- Synapse's retrieval quality (semantic recall, MMR) is unused by ralph's own loop.
- Knowledge does not compound across the fleet; it stays siloed in per-repo JSON.

## Goal

Close the loop: ingest ralph's **verified** knowledge into Synapse as retrievable
documents, and retrieve it back into the triage/mine agent prompts before those
agents act — so knowledge compounds **across all repos in a tenant** while
respecting Synapse's multi-tenant RLS isolation.

Non-goals (YAGNI): ingesting resolved signals or triage findings; per-repo
namespacing; injecting context into every main-loop iteration; any change to
Synapse itself.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Direction | **Closed loop** — ingest + retrieve |
| Tenancy | **Per-tenant** — knowledge lives in the tenant ralph runs under; compounds across that tenant's repos, respects RLS |
| What to ingest | **Verified skills + mined themes only** (both already trust-gated) |
| Structure | **Dedicated `lib/memory.sh`** unit + grounding hook (approach A) |
| Sync cadence | **Once per patrol tick** (not per loop iteration) |
| Retrieval injection | **triage fix-ci / fix-security + mine propose** prompts only |

## Architecture

New module `lib/memory.sh`, sourced alongside the other libs. All Synapse-facing
logic lives behind three public functions; the rest of ralph never touches Synapse
directly.

```
lib/memory.sh
├── memory_sync              reconcile local verified knowledge → Synapse (idempotent)
├── memory_ground <query>    retrieve a prompt-injectable context block (fail-open)
└── handle_memory_command    CLI: ralph memory [--sync] [--ground <q>]
```

Dependencies:
- `synapse.sh` — `synapse_ground` (existing, fail-open), plus a new
  `_synapse_ingest_doc` helper that POSTs `/documents.ingest`.
- `skills.sh` — read verified skills (files where `verified==true`).
- `mine.sh` — `_mine_scan` for ranked themes.
- `signals.sh` — `record_signal` to record `memory_sync_failed` on error.

### Isolation contract

- **What it does:** one-way reconcile of local knowledge into Synapse, and a thin
  read wrapper for retrieval.
- **How you use it:** `ralph memory --sync` (patrol, per tick) and
  `memory_ground <query>` (called by triage/mine prompt builders).
- **What it depends on:** the four libs above; a reachable Synapse (optional —
  everything fails open).

## Data model — the Synapse document

One document per knowledge item, keyed by a **stable `doc_id`** so re-sync is a
no-op. Synapse's idempotent ingest (#49) turns a byte-identical re-ingest into a
`"replayed"` response — no re-embedding, no duplicates.

### Verified skill
- `doc_id`   = `ralph-skill-<theme_key sha1[:12]>`
- `source_uri` = `ralph://skill/<theme_key>`
- `title`    = the skill's trigger text
- `content`  = trigger + action + why (the durable lesson)
- `metadata` = `{ kind: "ralph_skill", verified: true, theme: <theme_key> }`
- `owners`   = `["agent:ralph"]`
- `content_type` = `text/plain`, `language` = `en`, `source_system` = `ralph`

### Mined theme
- `doc_id`   = `ralph-theme-<theme sha1[:12]>`
- `source_uri` = `ralph://theme/<theme>`
- `title`    = `"<kind> failures on <tool>/<tier>"`
- `content`  = kind/tool/tier + frequency + distinct_runs + `_mine_action` guidance
- `metadata` = `{ kind: "ralph_theme", regress: <bool>, frequency: <n> }`
- `owners`, `content_type`, `language`, `source_system` as above

Tenant = current `SYNAPSE_TENANT`. The stable doc_id derives only from the
theme/skill key (not from volatile counts), so counts changing updates the same
document rather than forking a new one — but because `content` includes the count,
a real change re-ingests (not `replayed`), keeping retrieval fresh.

## Sync flow (`memory_sync`)

1. Preflight: if Synapse is unreachable (`synapse_ping` fails) → log, return 0.
2. Read verified skills (`verified==true`), build one skill doc each.
3. Read `_mine_scan` themes passing the `--feed` gate (`frequency≥3` **and**
   `distinct_runs≥2`), build one theme doc each.
4. `_synapse_ingest_doc` per item; tally `ingested` vs `replayed`.
5. Print `memory: synced N (X ingested, Y replayed, Z failed)`.
6. On any per-item failure: `record_signal memory_sync_failed …` (deduped by theme)
   and continue — never abort the batch.

**Trigger:** the patrol runs `ralph memory --sync` once per tick, after mine/skills
settle. Also runnable manually via `ralph memory --sync`.

## Retrieve flow (`memory_ground`)

`memory_ground <query>` wraps `synapse_ground` (which already returns a
`<synapse_context>…</synapse_context>` block, capped per result, and already fails
open to empty output). Injection points (targeted, not the whole loop):

- **triage fix-ci / fix-security** prompt builders: query = failing check name +
  repo. The fixer sees prior lessons on similar failures before proposing a fix.
- **mine propose** prompt builder: query = the top theme string.

The block is prepended to the agent prompt. When Synapse is down or has nothing,
the block is empty and the agent runs exactly as today.

## Error handling — fail-open, always

Autonomy must never depend on Synapse being up.

| Failure | Behavior |
|---|---|
| Synapse unreachable at sync | `memory_sync` logs, returns 0, ingests nothing |
| Single doc ingest fails | record `memory_sync_failed` (deduped), continue batch, return 0 |
| Synapse unreachable at retrieve | `memory_ground` returns empty; agent runs unaugmented |
| Auth/loopback guard fails | existing `synapse_auth_guard` short-circuits; treated as unreachable |

## Testing (`tests/test_memory.sh`)

Stubbed Synapse functions (ralph's TDD idiom — override `_synapse_call` /
`synapse_ping` / `_synapse_ingest_doc` with shell stubs). Assertions:

1. **doc_id stability** — same skill/theme → identical doc_id across two runs.
2. **verified-only filter** — an unverified skill is never ingested.
3. **theme gate** — a theme below `frequency≥3 ∧ distinct_runs≥2` is skipped.
4. **idempotent path** — second sync of unchanged knowledge → all `replayed`, none `ingested`.
5. **content refresh** — a theme whose frequency changed re-ingests (not replayed).
6. **fail-open sync** — ingest stub returns error → `memory_sync` returns 0 and
   records exactly one `memory_sync_failed` signal.
7. **fail-open ground** — `synapse_ground` stub errors → `memory_ground` prints
   nothing and returns 0.
8. **ground formatting** — a stubbed retrieve result is wrapped in a
   `<synapse_context>` block.

Registered in `tests/run_all.sh`.

## Rollout

- Behind the existing Synapse config; no new required env. If `SYNAPSE_URL` is
  unset/unreachable, the whole feature is inert (fail-open).
- Patrol wiring (`ralph memory --sync` per tick) added to `scripts/org-patrol`
  guarded so a sync failure only warns, never fails the tick.
- Ships source-only; no change to Synapse or to the autonomous merge boundary.
