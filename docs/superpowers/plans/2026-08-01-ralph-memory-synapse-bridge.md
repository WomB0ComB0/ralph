# Ralph memory → Synapse bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest ralph's verified skills and mined failure themes into Synapse as idempotent documents, and retrieve them back into fix-agent prompts, so knowledge compounds across all repos in a tenant.

**Architecture:** A new isolated `lib/memory.sh` module exposes `memory_sync` (reconcile local verified knowledge → Synapse via `/documents.ingest`, keyed by a stable doc_id so re-sync is a no-op), `memory_ground` (thin fail-open retrieval wrapper), and `handle_memory_command` (CLI). A single Synapse primitive `_synapse_ingest_doc` is added to `lib/synapse.sh`. Retrieval is injected once, in `_triage_apply_fix` — the shared chokepoint for fix-ci, fix-security, and mine-propose.

**Tech Stack:** Bash 3.2-compatible shell, `jq`, `curl` (all already used); Synapse REST (`/documents.ingest`, `/retrieve`, `/health`).

## Global Constraints

- Bash 3.2 compatible; every script uses `set -euo pipefail` conventions already in the libs — do not rely on bash 4+ features (no associative arrays, no `${x^^}`).
- **Fail-open everywhere:** no Synapse error, timeout, or absence may cause a non-zero exit from `memory_sync` or `memory_ground`, or block any caller. Autonomy must not depend on Synapse being up.
- Reuse existing helpers verbatim: `_synapse_call`, `synapse_ping`, `synapse_ground`, `_syn_tenant`, `_syn_principal`, `_signal_sha1`, `record_signal`, `_mine_scan`, `_mine_action`. Do not reimplement them.
- Local storage paths (defaults): skills `${SKILL_DIR:-.ralph/artifacts/skills}/<theme>.json`, signals `${SIGNAL_DIR:-.ralph/artifacts/signals}/<theme>.json`.
- Theme gate for mined knowledge matches `mine_feed`: `frequency >= 3 AND distinct_runs >= 2`.
- Tenant = current `SYNAPSE_TENANT` (via `_syn_tenant`); owners = `["agent:ralph"]`; `source_system: "ralph"`, `content_type: "text/plain"`, `language: "en"`.
- Every task ends green: run the full suite with `bash tests/run_all.sh` before the final commit of each task that touches shared files.

---

### Task 1: `_synapse_ingest_doc` primitive in lib/synapse.sh

**Files:**
- Modify: `lib/synapse.sh` (add one function beside the other `synapse_*` wrappers, after `synapse_run_resume` ~line 144)
- Test: `tests/test_synapse.sh` (append a block before the final TOTAL print)

**Interfaces:**
- Consumes: `_synapse_call POST /documents.ingest <principal> <body>` (returns 0 on 2xx, prints response body), `_syn_tenant`, `_syn_principal`.
- Produces: `_synapse_ingest_doc <doc_json>` → injects `tenant_id`, POSTs `/documents.ingest`, prints the raw response JSON, returns `_synapse_call`'s rc. The doc_json must already contain `doc_id, source_system, source_uri, title, content_type, language, owners, metadata, content`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_synapse.sh` (before the final `echo "TOTAL..."` / exit). If the file has no `TMP=$(mktemp -d)` yet, add one with `trap 'rm -rf "$TMP"' EXIT` near the top; otherwise reuse the existing temp dir:

```bash
echo "== _synapse_ingest_doc injects tenant_id and posts /documents.ingest =="
_synapse_call() { printf '%s|%s|%s' "$1" "$2" "$4" >"$TMP/ingest_call"; printf '{"status":"ingested","doc_id":"d1"}'; }
SYNAPSE_TENANT=acme
doc='{"doc_id":"d1","source_system":"ralph","source_uri":"ralph://x/1","title":"t","content_type":"text/plain","language":"en","owners":["agent:ralph"],"metadata":{"kind":"ralph_skill"},"content":"c"}'
resp=$(_synapse_ingest_doc "$doc")
IFS='|' read -r m p b <"$TMP/ingest_call"
eq "posts to /documents.ingest" "POST /documents.ingest" "$m $p"
eq "tenant_id injected into body" "acme" "$(printf '%s' "$b" | jq -r '.tenant_id')"
eq "doc_id preserved" "d1" "$(printf '%s' "$b" | jq -r '.doc_id')"
eq "returns response status" "ingested" "$(printf '%s' "$resp" | jq -r '.status')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_synapse.sh`
Expected: FAIL — `_synapse_ingest_doc: command not found` (or the eq assertions fail).

- [ ] **Step 3: Write minimal implementation**

In `lib/synapse.sh`, after the `synapse_run_resume()` line (~144):

```bash
# POST /documents.ingest — ingest one document. Injects tenant_id; expects the
# caller to supply doc_id/source_uri/title/content/metadata/owners. Prints the raw
# response JSON (contains {"status":"ingested"|"replayed", ...}); returns _synapse_call rc.
_synapse_ingest_doc() {
    local doc="$1" principal; principal="$(_syn_principal)"
    command_exists jq || return 1
    local body; body=$(jq -c --arg t "$(_syn_tenant)" '. + {tenant_id:$t}' <<<"$doc") || return 1
    _synapse_call POST /documents.ingest "$principal" "$body"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_synapse.sh`
Expected: PASS (all four eq lines) and the suite TOTAL unchanged otherwise.

- [ ] **Step 5: Commit**

```bash
git add lib/synapse.sh tests/test_synapse.sh
git commit -m "feat(synapse): add _synapse_ingest_doc primitive for /documents.ingest"
```

---

### Task 2: `lib/memory.sh` skeleton + `memory_ground`

**Files:**
- Create: `lib/memory.sh`
- Test: `tests/test_memory.sh` (create)
- Modify: `tests/run_all.sh` (register the new suite)

**Interfaces:**
- Consumes: `synapse_ground <query> [principal]` (existing; prints a `<synapse_context>…</synapse_context>` block or nothing; already fails open).
- Produces: `memory_ground <query>` → prints the context block (or empty), always returns 0.

- [ ] **Step 1: Write the failing test**

Create `tests/test_memory.sh`:

```bash
#!/bin/bash
# TDD harness for the ralph memory → Synapse bridge (lib/memory.sh).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/skills.sh"
source "$R/lib/github.sh"
source "$R/lib/triage.sh"
source "$R/lib/mine.sh"
source "$R/lib/synapse.sh"
source "$R/lib/memory.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== memory_ground wraps synapse_ground and is fail-open =="
synapse_ground() { printf '<synapse_context>\n- (ralph://skill/x) lesson\n</synapse_context>\n'; }
out=$(memory_ground "some query"); rc=$?
eq "ground returns 0" "0" "$rc"
printf '%s' "$out" | grep -q '<synapse_context>' && ok "ground emits context block" || bad "no block: $out"
synapse_ground() { return 7; }
out=$(memory_ground "q"); rc=$?
eq "ground fail-open rc 0" "0" "$rc"
eq "ground fail-open empty" "" "$out"

echo "TOTAL test_memory: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_memory.sh`
Expected: FAIL — `lib/memory.sh` does not exist (`source` error) or `memory_ground: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/memory.sh`:

```bash
#!/bin/bash
# lib/memory.sh — ralph memory ↔ Synapse bridge.
# Ingests verified skills + mined failure themes into Synapse as idempotent
# documents, and retrieves them back into fix-agent prompts. Fail-open: no Synapse
# error ever blocks a caller. Depends on: synapse.sh (_synapse_ingest_doc,
# synapse_ping, synapse_ground), skills.sh (skill files), mine.sh (_mine_scan,
# _mine_action), signals.sh (record_signal), utils.sh (_signal_sha1).

# Retrieve a prompt-injectable <synapse_context> block for a query. Always rc 0.
memory_ground() {
    local query="${1:-}"
    [[ -n "$query" ]] || return 0
    declare -F synapse_ground >/dev/null || return 0
    synapse_ground "$query" 2>/dev/null || return 0
    return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_memory.sh`
Expected: PASS (both ground assertions, fail-open assertions).

- [ ] **Step 5: Register the suite**

In `tests/run_all.sh`, add `test_memory.sh` to the list of suites (follow the exact pattern used for `test_mine.sh` — locate the line referencing `test_mine.sh` and add an analogous entry).

- [ ] **Step 6: Run the whole suite**

Run: `bash tests/run_all.sh`
Expected: all suites green, including the new `test_memory`.

- [ ] **Step 7: Commit**

```bash
git add lib/memory.sh tests/test_memory.sh tests/run_all.sh
git commit -m "feat(memory): add lib/memory.sh with fail-open memory_ground"
```

---

### Task 3: `memory_sync` — reconcile verified knowledge → Synapse

**Files:**
- Modify: `lib/memory.sh` (add `memory_sync` and a private `_memory_ingest_one`)
- Test: `tests/test_memory.sh` (append blocks before the TOTAL line)

**Interfaces:**
- Consumes: `_synapse_ingest_doc <doc_json>` (Task 1; prints `{"status":...}`), `synapse_ping` (rc 0 iff healthy), `_mine_scan` (prints ranked theme array), `_mine_action`, `_signal_sha1`, `record_signal`, skill files under `$SKILL_DIR`.
- Produces: `memory_sync` → ingests one doc per verified skill and per qualifying theme; prints `memory: synced N (X ingested, Y replayed, Z failed)`; always returns 0. Private `_memory_ingest_one <doc_json> <theme>` → ingests, echoes the resulting status word (`ingested`/`replayed`/`failed`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_memory.sh` (before the `echo "TOTAL..."` line):

```bash
echo "== memory_sync: verified-only skills, theme gate, tally, idempotency =="
SKILL_DIR="$TMP/skills"; SIGNAL_DIR="$TMP/sig"; mkdir -p "$SKILL_DIR" "$SIGNAL_DIR"
printf '{"theme_key":"typefix","problem":"TS2345 arg type","resolution":"add annotation","verified":true}\n'  >"$SKILL_DIR/typefix.json"
printf '{"theme_key":"draft","problem":"x","resolution":"y","verified":false}\n' >"$SKILL_DIR/draft.json"
LEDGER="$TMP/metrics.json"
for i in 1 2; do printf '{"run_id":"r1","iteration":%s,"tool":"opencode","model":"opus","tokens":10,"lazy_streak":3,"changed":true,"verify_ok":false}\n' "$i" >>"$LEDGER"; done
printf '{"run_id":"r2","iteration":1,"tool":"opencode","model":"opus","tokens":10,"lazy_streak":3,"changed":true,"verify_ok":false}\n' >>"$LEDGER"

synapse_ping() { return 0; }
SEEN="$TMP/seen"; : >"$SEEN"
_synapse_ingest_doc() {
  local id; id=$(printf '%s' "$1" | jq -r '.doc_id')
  printf '%s\n' "$1" >>"$TMP/docs.log"
  if grep -qx "$id" "$SEEN" 2>/dev/null; then printf '{"status":"replayed","doc_id":"%s"}' "$id"
  else printf '%s\n' "$id" >>"$SEEN"; printf '{"status":"ingested","doc_id":"%s"}' "$id"; fi
}

out=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LEDGER" memory_sync); rc=$?
eq "sync returns 0" "0" "$rc"
eq "one skill + one theme ingested (2)" "2" "$(printf '%s' "$out" | sed -n 's/.*synced \([0-9]*\).*/\1/p')"
printf '%s' "$out" | grep -q '2 ingested' && ok "tally: 2 ingested" || bad "tally wrong: $out"
grep -q '"draft"' "$TMP/docs.log" 2>/dev/null && bad "unverified skill leaked" || ok "verified-only filter holds"
out2=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LEDGER" memory_sync)
printf '%s' "$out2" | grep -q '0 ingested, 2 replayed' && ok "idempotent re-sync: all replayed" || bad "not idempotent: $out2"

echo "== memory_sync: theme below gate is skipped =="
LOW="$TMP/low.json"
printf '{"run_id":"r9","iteration":1,"tool":"agy","model":"gemini","tokens":10,"lazy_streak":3,"changed":true,"verify_ok":false}\n' >"$LOW"
: >"$TMP/docs2.log"
_synapse_ingest_doc() { printf '%s\n' "$1" >>"$TMP/docs2.log"; printf '{"status":"ingested"}'; }
mkdir -p "$TMP/empty"
SKILL_DIR="$TMP/empty" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LOW" memory_sync >/dev/null
[[ -s "$TMP/docs2.log" ]] && bad "below-gate theme was ingested" || ok "theme gate holds (freq<3)"

echo "== memory_sync: fail-open + records memory_sync_failed =="
synapse_ping() { return 0; }
_synapse_ingest_doc() { return 42; }
rc=0; out=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LEDGER" memory_sync) || rc=$?
eq "sync fail-open rc 0" "0" "$rc"
printf '%s' "$out" | grep -q 'failed' && ok "tally reports failures" || bad "no failure tally: $out"
ls "$SIGNAL_DIR"/*.json >/dev/null 2>&1 && ok "memory_sync_failed signal recorded" || bad "no failure signal recorded"

echo "== memory_sync: unreachable Synapse is a clean no-op =="
synapse_ping() { return 1; }
out=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$TMP/sig3" METRICS_FILE="$LEDGER" memory_sync); rc=$?
eq "unreachable rc 0" "0" "$rc"
printf '%s' "$out" | grep -q 'synced 0' && ok "no-op when Synapse down" || bad "not a no-op: $out"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_memory.sh`
Expected: FAIL — `memory_sync: command not found`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/memory.sh` (above `memory_ground` is fine — order does not matter):

```bash
# Ingest one document; echo the status word. On transport failure, record a deduped
# memory_sync_failed signal and echo "failed". Never returns non-zero.
_memory_ingest_one() {
    local doc="$1" theme="$2" resp status
    if resp=$(_synapse_ingest_doc "$doc" 2>/dev/null); then
        status=$(printf '%s' "$resp" | jq -r '.status // "ingested"' 2>/dev/null)
        [[ "$status" == "ingested" || "$status" == "replayed" ]] || status="ingested"
        printf '%s' "$status"
    else
        record_signal memory_sync_failed \
            "Synapse ingest failed for memory doc" \
            "memory ingest theme $theme" \
            "check Synapse /documents.ingest reachability and auth" \
            "memory,ingest" "low" "memory" >/dev/null 2>&1 || true
        printf 'failed'
    fi
}

# Reconcile verified skills + qualifying mined themes into Synapse. Fail-open.
memory_sync() {
    command_exists jq || { printf 'memory: synced 0 (jq unavailable)\n'; return 0; }
    if declare -F synapse_ping >/dev/null; then
        synapse_ping >/dev/null 2>&1 || { printf 'memory: synced 0 (Synapse unreachable)\n'; return 0; }
    fi
    local ingested=0 replayed=0 failed=0 total=0 st

    # Verified skills.
    local kdir="${SKILL_DIR:-.ralph/artifacts/skills}" kf theme problem resolution hash doc_id content doc
    if [[ -d "$kdir" ]]; then
        for kf in "$kdir"/*.json; do
            [[ -f "$kf" ]] || continue
            jq -e '.verified==true' "$kf" >/dev/null 2>&1 || continue
            theme=$(jq -r '.theme_key // ""' "$kf" 2>/dev/null); [[ -n "$theme" ]] || continue
            problem=$(jq -r '.problem // ""' "$kf" 2>/dev/null)
            resolution=$(jq -r '.resolution // ""' "$kf" 2>/dev/null)
            hash=$(printf '%s' "$theme" | _signal_sha1 2>/dev/null | cut -c1-12)
            doc_id="ralph-skill-$hash"
            content="Trigger: $problem"$'\n'"Fix: $resolution"
            doc=$(jq -nc --arg id "$doc_id" --arg uri "ralph://skill/$theme" --arg title "$problem" \
                --arg content "$content" --arg theme "$theme" \
                '{doc_id:$id, source_system:"ralph", source_uri:$uri, title:$title,
                  content_type:"text/plain", language:"en", owners:["agent:ralph"],
                  metadata:{kind:"ralph_skill", verified:true, theme:$theme}, content:$content}') || continue
            st=$(_memory_ingest_one "$doc" "$theme")
            total=$((total+1)); case "$st" in ingested) ingested=$((ingested+1));; replayed) replayed=$((replayed+1));; *) failed=$((failed+1));; esac
        done
    fi

    # Mined themes passing the feed gate (freq>=3 AND distinct_runs>=2).
    local scan qualifying tkey kind tool tier freq runs reg regj
    scan=$(_mine_scan 2>/dev/null)
    qualifying=$(printf '%s' "$scan" | jq -r '
        .[] | select(.frequency >= 3 and .distinct_runs >= 2)
        | [.theme,.kind,.tool,.tier,(.frequency|tostring),(.distinct_runs|tostring),(.regress|tostring)] | @tsv' 2>/dev/null)
    while IFS=$'\t' read -r tkey kind tool tier freq runs reg; do
        [[ -n "$tkey" ]] || continue
        hash=$(printf '%s' "$tkey" | _signal_sha1 2>/dev/null | cut -c1-12)
        doc_id="ralph-theme-$hash"
        content="Recurring $kind failures on $tool/$tier: $freq iterations across $runs runs. $(_mine_action "$kind")"
        [[ "$reg" == "true" ]] && regj=true || regj=false
        doc=$(jq -nc --arg id "$doc_id" --arg uri "ralph://theme/$tkey" \
            --arg title "$kind failures on $tool/$tier" --arg content "$content" \
            --argjson freq "$freq" --argjson reg "$regj" \
            '{doc_id:$id, source_system:"ralph", source_uri:$uri, title:$title,
              content_type:"text/plain", language:"en", owners:["agent:ralph"],
              metadata:{kind:"ralph_theme", regress:$reg, frequency:$freq}, content:$content}') || continue
        st=$(_memory_ingest_one "$doc" "$tkey")
        total=$((total+1)); case "$st" in ingested) ingested=$((ingested+1));; replayed) replayed=$((replayed+1));; *) failed=$((failed+1));; esac
    done <<< "$qualifying"

    printf 'memory: synced %s (%s ingested, %s replayed, %s failed)\n' "$total" "$ingested" "$replayed" "$failed"
    return 0
}
```

Note: `_mine_action` and `_mine_scan` are defined in `lib/mine.sh` (already sourced); `record_signal` writes into `${SIGNAL_DIR}` — the test overrides `SIGNAL_DIR` per case.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_memory.sh`
Expected: PASS — all sync assertions (tally, verified-only, idempotent replay, theme gate, fail-open + signal, unreachable no-op).

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run_all.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/memory.sh tests/test_memory.sh
git commit -m "feat(memory): memory_sync ingests verified skills + mined themes (idempotent, fail-open)"
```

---

### Task 4: CLI `handle_memory_command` + sourcing + dispatch

**Files:**
- Modify: `lib/memory.sh` (add `handle_memory_command`)
- Modify: `ralph.sh` (source `lib/memory.sh` after `lib/synapse.sh`, line ~52)
- Modify: `lib/engine.sh` (add a `memory` dispatch block after the `mine` block, ~line 2249)
- Test: `tests/test_memory.sh` (append before TOTAL)

**Interfaces:**
- Consumes: `memory_sync`, `memory_ground`.
- Produces: `handle_memory_command [--sync] [--ground <q>]` — bare/`-h` call prints usage; `--sync` runs `memory_sync`; `--ground <q>` prints the block. `ralph memory …` dispatches to it.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_memory.sh` (before `echo "TOTAL..."`):

```bash
echo "== handle_memory_command dispatch =="
synapse_ping() { return 1; }   # force clean no-op path
mkdir -p "$TMP/empty"
o=$(SKILL_DIR="$TMP/empty" SIGNAL_DIR="$TMP/s4" handle_memory_command --sync 2>&1)
printf '%s' "$o" | grep -q '^memory: synced' && ok "--sync runs memory_sync" || bad "--sync failed: $o"
o=$(handle_memory_command 2>&1)
printf '%s' "$o" | grep -qi 'usage' && ok "bare prints usage" || bad "no usage: $o"

echo "== ralph.sh memory subcommand dispatches =="
e=$(cd "$R" && SKILL_DIR="$TMP/empty" SYNAPSE_URL="http://127.0.0.1:9" ./ralph.sh memory --sync 2>&1)
printf '%s' "$e" | grep -q '^memory: synced' && ok "ralph.sh memory dispatches" || bad "dispatch failed: $e"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_memory.sh`
Expected: FAIL — `handle_memory_command: command not found` and the `ralph.sh memory` line errors.

- [ ] **Step 3: Implement the CLI, sourcing, and dispatch**

Add to `lib/memory.sh`:

```bash
# CLI entrypoint: ralph memory [--sync] [--ground <query>]
handle_memory_command() {
    local do_sync=0 ground_q="" saw=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sync)   do_sync=1; saw=1 ;;
            --ground) ground_q="${2:-}"; saw=1; shift ;;
            -h|--help) saw=0; break ;;
            *) log_warning "memory: ignoring unknown argument: $1" ;;
        esac
        shift
    done
    if [[ "$saw" == "0" ]]; then
        printf 'usage: ralph memory [--sync] [--ground <query>]\n'
        printf '  --sync            ingest verified skills + mined themes into Synapse (idempotent)\n'
        printf '  --ground <query>  print a <synapse_context> block for <query> (fail-open)\n'
        return 0
    fi
    [[ "$do_sync" == "1" ]] && memory_sync
    [[ -n "$ground_q" ]] && memory_ground "$ground_q"
    return 0
}
```

In `ralph.sh`, after the `source "$SCRIPT_DIR/lib/synapse.sh"` line (52):

```bash
source "$SCRIPT_DIR/lib/memory.sh"
```

In `lib/engine.sh`, after the `mine` dispatch block (ends ~line 2249), add:

```bash
    if [[ "${1:-}" == "memory" ]]; then
        shift
        handle_memory_command "$@"
        exit $?
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_memory.sh`
Expected: PASS — `--sync`, usage, and `ralph.sh memory` dispatch all succeed.

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run_all.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/memory.sh ralph.sh lib/engine.sh tests/test_memory.sh
git commit -m "feat(memory): ralph memory --sync/--ground CLI + dispatch + sourcing"
```

---

### Task 5: Inject `memory_ground` into `_triage_apply_fix`

**Files:**
- Modify: `lib/triage.sh` (add `_triage_ground_prompt` just above `_triage_apply_fix` at line 549; call it inside `_triage_apply_fix` right after the `local … prompt="$4" …` line at 550)
- Test: `tests/test_triage.sh` (append a focused block before the final TOTAL)

**Interfaces:**
- Consumes: `memory_ground <query>` (Task 2). `_triage_apply_fix` already has `prompt` and `title` locals.
- Produces: `_triage_ground_prompt <query> <prompt>` → prints `<block>\n\n<prompt>` when `memory_ground` yields a non-empty block, else the original `<prompt>` unchanged. Wired into `_triage_apply_fix` so all three callers (fix-ci, fix-security, mine-propose) get grounding at one point.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_triage.sh` (before the final TOTAL/exit):

```bash
echo "== _triage_ground_prompt prepends memory context when present =="
memory_ground() { printf '<synapse_context>\n- prior lesson\n</synapse_context>\n'; }
p=$(_triage_ground_prompt "fix the CI typecheck" "original prompt body")
printf '%s' "$p" | grep -q '<synapse_context>' && ok "context prepended" || bad "no context: $p"
printf '%s' "$p" | grep -q 'original prompt body' && ok "original prompt retained" || bad "prompt lost: $p"
memory_ground() { return 0; }
p=$(_triage_ground_prompt "q" "just the body")
eq "empty ground leaves prompt intact" "just the body" "$p"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_triage.sh`
Expected: FAIL — `_triage_ground_prompt: command not found`.

- [ ] **Step 3: Implement the helper and wire it in**

In `lib/triage.sh`, add the pure helper just above `_triage_apply_fix()` (line 549):

```bash
# Prepend a Synapse memory-context block (if any) to a fix prompt. Fail-open:
# any error or empty result yields the original prompt unchanged.
_triage_ground_prompt() {
    local query="$1" prompt="$2" block=""
    declare -F memory_ground >/dev/null && block=$(memory_ground "$query" 2>/dev/null || true)
    if [[ -n "$block" ]]; then
        printf '%s\n\n%s' "$block" "$prompt"
    else
        printf '%s' "$prompt"
    fi
}
```

Then inside `_triage_apply_fix`, immediately after the locals line (550: `local repo="$1" base_branch="$2" … finding_key="${9:-}"`), add:

```bash
    prompt=$(_triage_ground_prompt "$title" "$prompt")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_triage.sh`
Expected: PASS (context prepended, original retained, empty-ground unchanged).

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run_all.sh`
Expected: all green (existing triage tests unaffected — the prepend is a no-op when `memory_ground` is undefined or returns empty).

- [ ] **Step 6: Commit**

```bash
git add lib/triage.sh tests/test_triage.sh
git commit -m "feat(triage): ground fix prompts with Synapse memory via _triage_apply_fix"
```

---

### Task 6: Patrol wiring — `ralph memory --sync` per tick

**Files:**
- Modify: `scripts/org-patrol` (add a guarded sync step after the triage/verify pass, near the existing `--verify-fixes` block ~line 301)
- Test: `tests/test_org_scripts.sh` (append an assertion that the patrol invokes memory sync)

**Interfaces:**
- Consumes: the `ralph` binary resolved by the patrol as `$ralph_bin` (already used for `triage --verify-fixes`).
- Produces: after each patrol tick's triage pass, `"$ralph_bin" memory --sync` runs; a failure only warns (never fails the tick).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_org_scripts.sh` (before the final TOTAL). Follow the existing harness idiom in that file (it stubs `ralph`/`gh` and captures invocations). If the file already runs a full patrol tick with a logging `ralph` stub whose calls land in a capture file, assert against it:

```bash
echo "== org-patrol runs 'memory --sync' after the triage pass =="
grep -q 'memory --sync' "$CALLS" && ok "patrol invokes memory --sync" || bad "no memory --sync in: $(cat "$CALLS")"
```

If no such full-tick harness exists yet, add one modeled on the existing `preflight`/`verify-fixes` test: set `RALPH_ORG_TRIAGE_MODE=suggest-apply`, point `RALPH_ORG_TARGETS_FILE` at a temp file containing one repo, create a `ralph` stub on `PATH` that appends `"$*"` to `$CALLS` (`CALLS="$TMP/calls"`), run `scripts/org-patrol --org test --no-synapse-check --no-soak-summary --no-preflight`, then assert the grep above.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_org_scripts.sh`
Expected: FAIL — no `memory --sync` recorded.

- [ ] **Step 3: Implement the patrol step**

In `scripts/org-patrol`, after the triage dispatch and the existing `--verify-fixes` `case` block (~line 301-303) and before `write_soak_summary`/exit handling, add an unconditional guarded sync (memory sync is safe in every mode — it only reads local verified knowledge and is fail-open):

```bash
# Compounding memory: push verified skills + mined themes into Synapse. Fail-open;
# a sync failure must never fail the patrol tick.
"$ralph_bin" memory --sync || printf 'WARNING: memory --sync failed (non-fatal)\n' >&2
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_org_scripts.sh`
Expected: PASS — `memory --sync` logged.

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run_all.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add scripts/org-patrol tests/test_org_scripts.sh
git commit -m "feat(patrol): sync ralph memory to Synapse each tick (fail-open)"
```

---

### Task 7: Docs + README

**Files:**
- Modify: `README.md` (document `ralph memory --sync` / `--ground`, the closed-loop behavior, and fail-open semantics — add near the `ralph mine` and Synapse sections)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add the documentation**

In `README.md`, add a short subsection near the existing `mine`/Synapse docs:

```markdown
### `ralph memory` — compounding memory via Synapse

Ralph's verified skills and mined failure themes can compound **across repos** through
Synapse (the org-brain retrieval service):

- `ralph memory --sync` ingests every verified skill and every qualifying mined theme
  (`frequency ≥ 3` across `≥ 2` runs) into Synapse as idempotent documents (stable
  `doc_id`; unchanged items are `replayed`, not re-embedded). The org patrol runs this
  each tick.
- `ralph memory --ground "<query>"` prints a `<synapse_context>` block of prior lessons.
  Fix agents (CI, security, mine-propose) are automatically grounded with this context
  before they act, via `_triage_apply_fix`.

Everything is **fail-open**: if Synapse is unset, unreachable, or erroring, `memory`
does nothing and never blocks a run. Knowledge stays scoped to the current
`SYNAPSE_TENANT`, respecting Synapse's multi-tenant isolation.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document ralph memory --sync/--ground closed-loop bridge"
```

---

## Self-Review

**Spec coverage:**
- Closed loop (ingest + retrieve) → Tasks 3 (ingest) + 5 (retrieve). ✓
- Per-tenant → tenant injected via `_syn_tenant` in Task 1 helper; docs never cross tenants. ✓
- Verified skills + mined themes only → Task 3 filters `verified==true` and the `freq≥3 ∧ runs≥2` gate. ✓
- Dedicated `lib/memory.sh` (approach A) → Tasks 2-4. ✓
- Stable doc_id / idempotency (#49) → Task 3 doc_id from theme/skill key; idempotency test asserts `replayed`. ✓
- Sync per patrol tick → Task 6. ✓
- Retrieval into triage-fix + mine-propose → Task 5 injects at the shared `_triage_apply_fix` chokepoint (covers fix-ci, fix-security, mine-propose in one point — a DRYer realization of the spec's two named points, same behavior). ✓
- Fail-open everywhere → Tasks 2, 3, 5, 6 each assert or guarantee rc 0 on Synapse failure. ✓
- Error handling records `memory_sync_failed` → Task 3. ✓
- Testing (`tests/test_memory.sh`, run_all registration) → Tasks 2-4. ✓

**Placeholder scan:** none — every code step is concrete.

**Type/name consistency:** `_synapse_ingest_doc` (Task 1) consumed in Task 3; `memory_ground` (Task 2) consumed in Tasks 4 & 5; `memory_sync` (Task 3) consumed in Tasks 4 & 6; `_triage_ground_prompt` defined and consumed in Task 5. Status words `ingested`/`replayed`/`failed` consistent between `_memory_ingest_one` and the `memory_sync` tally. ✓

**One deviation from the spec, noted for the reviewer:** the spec named two injection points (triage fix + mine propose). Because `mine_propose` and the triage fix functions all call `_triage_apply_fix`, Task 5 injects once there — strictly simpler, same coverage. No behavior lost.
