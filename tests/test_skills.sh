#!/bin/bash
# TDD harness for guarded skill-authoring (lib/skills.sh), built on the signals layer.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/skills.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SIGNAL_DIR="$TMP/signals" SIGNAL_ARCHIVE_DIR="$TMP/signals/.archive" LOG_MD="$TMP/LOG.md"
export SKILL_DIR="$TMP/skills" RUN_ID="r-1-1"

echo "== record_skill: create candidate, update resolution =="
rm -rf "$SKILL_DIR"
k=$(record_skill "validation-failure--cargo-e0432" "cargo check fails E0432" "add mod db; to main.rs" "rust,build")
eq "creates one skill file" 1 "$(find "$SKILL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
eq "status starts as candidate (guarded)" candidate "$(jq -r .status "$SKILL_DIR/$k.json")"
record_skill "validation-failure--cargo-e0432" "cargo check fails E0432" "add 'mod db;' AND the dep" "rust" >/dev/null
eq "same theme stays one file" 1 "$(find "$SKILL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
eq "resolution updated" "add 'mod db;' AND the dep" "$(jq -r .resolution "$SKILL_DIR/$k.json")"
jq empty "$SKILL_DIR/$k.json" 2>/dev/null && ok "skill is valid JSON" || bad "invalid JSON"

echo "== approve / reject lifecycle (the guard) =="
approve_skill "$k"; eq "approve -> approved" approved "$(jq -r .status "$SKILL_DIR/$k.json")"
reject_skill "$k";  eq "reject -> rejected"  rejected "$(jq -r .status "$SKILL_DIR/$k.json")"

echo "== recall_skills: ONLY approved skills matching an OPEN signal =="
rm -rf "$SKILL_DIR" "$SIGNAL_DIR"
sk=$(record_signal validation_failure "cargo fails" "error[E0432] in src/main.rs:1" "fix")
record_skill "$sk" "cargo E0432" "add mod db; to main.rs" "rust" >/dev/null
approve_skill "$sk"
sk2=$(record_signal runtime_failure "vet fails" "go vet error here" "fix vet")
record_skill "$sk2" "go vet" "run gofmt first" "go" >/dev/null
record_skill "loop-detected--something-old" "old loop" "do something else" >/dev/null
approve_skill "loop-detected--something-old"
out=$(recall_skills)
[[ "$out" == *"<skills>"* ]] && ok "wrapped in <skills>" || bad "no wrapper"
[[ "$out" == *"add mod db"* ]] && ok "surfaces approved skill for an open signal" || bad "approved+matching skill missing"
[[ "$out" != *"run gofmt first"* ]] && ok "does NOT surface candidate (unapproved) skill" || bad "candidate leaked"
[[ "$out" != *"do something else"* ]] && ok "does NOT surface approved skill with no open signal" || bad "non-matching skill leaked"

echo "== auto-capture: resolving a recurring signal with a note seeds a candidate skill =="
rm -rf "$SKILL_DIR" "$SIGNAL_DIR"
ak=$(record_signal validation_failure "cargo fails" "error[E0099] in src/x.rs:1" "fix")
record_signal validation_failure "cargo fails" "error[E0099] in src/x.rs:7" "fix" >/dev/null
signal_resolve "$ak" "added the missing import"
if [[ -f "$SKILL_DIR/$ak.json" ]]; then
    ok "resolving a freq>=2 signal with a note created a candidate skill"
    eq "skill resolution = the resolve note" "added the missing import" "$(jq -r .resolution "$SKILL_DIR/$ak.json")"
    eq "auto-captured skill is a candidate (still guarded)" candidate "$(jq -r .status "$SKILL_DIR/$ak.json")"
else
    bad "auto-capture did not create a skill"; bad "(resolution)"; bad "(status)"
fi

echo "== auto-resolve synthetic notes are NOT captured as skills =="
rm -rf "$SKILL_DIR" "$SIGNAL_DIR"
bk=$(record_signal validation_failure "x" "evid q here" "fix")
record_signal validation_failure "x" "evid q here2" "fix" >/dev/null
signal_resolve "$bk" "auto-resolved: clean for 2 iterations"
[[ ! -f "$SKILL_DIR/$bk.json" ]] && ok "synthetic auto-resolve note does not author a skill" || bad "synthetic note captured"

echo "== record_skill does not clobber an APPROVED skill's resolution =="
rm -rf "$SKILL_DIR"
record_skill "theme-x" "prob" "the vetted fix" "t" >/dev/null
approve_skill "theme-x"
record_skill "theme-x" "prob" "a worse later note" "t" >/dev/null
eq "approved resolution preserved" "the vetted fix" "$(jq -r .resolution "$SKILL_DIR/theme-x.json")"
eq "still approved" approved "$(jq -r .status "$SKILL_DIR/theme-x.json")"

echo "== signal_resolve preserves _signal_set rc (bad key -> non-zero) =="
signal_resolve "no-such-signal-key" "note" >/dev/null 2>&1 && bad "resolve of missing key returned 0" || ok "resolve of missing key returns non-zero"

echo "== global (cross-project) skills =="
export SIGNAL_DIR="$TMP/g_sig" SKILL_DIR="$TMP/g_sk" RALPH_GLOBAL_SKILL_DIR="$TMP/g_global"
export PROJECT_DIR="$TMP/myrepo" _RALPH_DIR="$TMP/myrepo/.ralph"   # provenance source for globalize
rm -rf "$SIGNAL_DIR" "$SKILL_DIR" "$RALPH_GLOBAL_SKILL_DIR"; init_signals; init_skills

# globalize requires an APPROVED skill
record_skill "cand-x" "p" "candidate res" >/dev/null   # left candidate
globalize_skill "cand-x" >/dev/null 2>&1 && bad "globalized a candidate" || ok "globalize refuses a non-approved skill"
[[ ! -f "$RALPH_GLOBAL_SKILL_DIR/cand-x.json" ]] && ok "no global file for a candidate" || bad "candidate leaked to global"

# globalize an approved skill -> copy into the global store with provenance
record_skill "appr-x" "p" "approved res" >/dev/null; approve_skill "appr-x"
globalize_skill "appr-x" >/dev/null
[[ -f "$RALPH_GLOBAL_SKILL_DIR/appr-x.json" ]] && ok "approved skill globalized" || bad "globalize did not write a global file"
eq "global scope tagged" global "$(jq -r '.scope // ""' "$RALPH_GLOBAL_SKILL_DIR/appr-x.json" 2>/dev/null)"
eq "origin_project = repo name (not .ralph)" myrepo "$(jq -r '.origin_project // ""' "$RALPH_GLOBAL_SKILL_DIR/appr-x.json" 2>/dev/null)"

# recall surfaces a GLOBAL skill when only the global copy exists (a different repo)
gk=$(record_signal validation_failure "z" "CROSSREPO problem" "fix")
record_skill "$gk" "p" "the cross-repo resolution" >/dev/null; approve_skill "$gk"; globalize_skill "$gk" >/dev/null
rm -f "$SKILL_DIR/$gk.json"   # simulate: only the global copy is present in this repo
out=$(recall_skills)
[[ "$out" == *"the cross-repo resolution"* ]] && ok "recall surfaces a global skill for an open signal" || bad "global skill not recalled"
[[ "$out" == *"cross-project"* ]] && ok "global skill tagged as cross-project" || bad "global skill not tagged"

# a local project skill takes precedence over a global one for the same theme
pk=$(record_signal runtime_failure "w" "PRECEDENCE problem" "fix")
record_skill "$pk" "p" "PROJECT resolution" >/dev/null; approve_skill "$pk"; globalize_skill "$pk" >/dev/null
tmpj=$(mktemp); jq '.resolution="GLOBAL VERSION"' "$RALPH_GLOBAL_SKILL_DIR/$pk.json" > "$tmpj" && mv "$tmpj" "$RALPH_GLOBAL_SKILL_DIR/$pk.json"
out2=$(recall_skills)
[[ "$out2" == *"PROJECT resolution"* ]] && ok "project skill wins over global" || bad "project precedence broken"
[[ "$out2" != *"GLOBAL VERSION"* ]] && ok "global copy not surfaced when a project skill exists" || bad "global leaked despite project skill"

# list_global_skills
[[ "$(list_global_skills)" == *"appr-x"* ]] && ok "list_global_skills lists globalized skills" || bad "global list missing entry"

# a locally REJECTED skill suppresses the global fallback (local reject must win)
rj=$(record_signal validation_failure "v" "REJECTLOCAL problem" "fix")
record_skill "$rj" "p" "local fix" >/dev/null; reject_skill "$rj"
printf '%s' "$(jq -n --arg t "$rj" '{theme_key:$t,resolution:"GLOBAL OVERRIDE",status:"approved",scope:"global"}')" > "$RALPH_GLOBAL_SKILL_DIR/$rj.json"
out3=$(recall_skills)
[[ "$out3" != *"GLOBAL OVERRIDE"* ]] && ok "locally-rejected theme suppresses the global fallback" || bad "rejected local skill leaked the global copy"

# a NON-approved global skill must never surface
ng=$(record_signal runtime_failure "u" "NONAPPROVEDGLOBAL problem" "fix")
printf '%s' "$(jq -n --arg t "$ng" '{theme_key:$t,resolution:"UNAPPROVED GLOBAL",status:"candidate",scope:"global"}')" > "$RALPH_GLOBAL_SKILL_DIR/$ng.json"
out4=$(recall_skills)
[[ "$out4" != *"UNAPPROVED GLOBAL"* ]] && ok "non-approved global skill is not surfaced" || bad "unapproved global leaked"

# a skill with a NULL/missing resolution must not break recall (jq + on null throws)
nr=$(record_signal validation_failure "nr" "NULLRES problem" "fix")
printf '%s' "$(jq -n --arg t "$nr" '{theme_key:$t,resolution:null,status:"approved",scope:"global"}')" > "$RALPH_GLOBAL_SKILL_DIR/$nr.json"
out5=$(recall_skills)
[[ "$out5" == *"(no resolution)"* ]] && ok "null-resolution skill shows a placeholder, not a blank/broken line" || bad "null resolution not handled gracefully"

# PROJECT_DIR="." must resolve to a real dir name, not "." or empty
( export PROJECT_DIR="."; record_skill "dotrepo-x" p r >/dev/null; approve_skill "dotrepo-x"; globalize_skill "dotrepo-x" >/dev/null )
odot=$(jq -r '.origin_project // ""' "$RALPH_GLOBAL_SKILL_DIR/dotrepo-x.json" 2>/dev/null)
[[ -n "$odot" && "$odot" != "." && "$odot" != "/" ]] && ok "PROJECT_DIR=. resolves to a real provenance name" || bad "origin is '.'/'/'/'empty (got [$odot])"

echo "== skill verification gate: promotion needs evidence, not the agent's word =="
export SIGNAL_DIR="$TMP/vg-sig" SIGNAL_ARCHIVE_DIR="$TMP/vg-sig/.archive" SKILL_DIR="$TMP/vg-skill"
rm -rf "$SIGNAL_DIR" "$SKILL_DIR"; init_signals; init_skills
vk=$(RALPH_NOW=2026-01-01T00:00:00Z record_signal validation_failure "cargo fails" "E0432 unresolved import" "add mod" "" medium)
RALPH_NOW=2026-01-01T00:00:00Z record_signal validation_failure "cargo fails" "E0432 unresolved import" "add mod" "" medium >/dev/null
RALPH_NOW=2026-01-01T00:05:00Z signal_resolve "$vk" "added 'mod db;' to main.rs" >/dev/null
eq "resolved recurring signal autocaptures a candidate" candidate "$(jq -r .status "$SKILL_DIR/$vk.json")"
eq "candidate starts UNVERIFIED" false "$(jq -r '.verified' "$SKILL_DIR/$vk.json")"

gout=$(handle_skill_command approve "$vk" 2>&1)
printf '%s' "$gout" | grep -qi 'Refusing to approve' && ok "CLI approve blocked for an unverified candidate" || bad "approve not blocked: $gout"
eq "blocked candidate stays candidate" candidate "$(jq -r .status "$SKILL_DIR/$vk.json")"

handle_skill_command approve "$vk" --force >/dev/null 2>&1
eq "--force approves despite the gate" approved "$(jq -r .status "$SKILL_DIR/$vk.json")"

_skill_set "$vk" '.status="candidate" | .verified=false' >/dev/null
signal_reopen "$vk"          # regression: signal reopens with regressed=true
verify_skills
eq "regressed signal rejects the candidate (fix did not hold)" rejected "$(jq -r .status "$SKILL_DIR/$vk.json")"
jq -r '.verify_reason // ""' "$SKILL_DIR/$vk.json" | grep -q regressed && ok "rejection records the regression reason" || bad "no verify_reason recorded"

export SIGNAL_DIR="$TMP/vg-sig2" SIGNAL_ARCHIVE_DIR="$TMP/vg-sig2/.archive" SKILL_DIR="$TMP/vg-skill2"
rm -rf "$SIGNAL_DIR" "$SKILL_DIR"; init_signals; init_skills
pk=$(RALPH_NOW=2020-01-01T00:00:00Z record_signal runtime_failure "vet fails" "gofmt drift" "run gofmt" "" medium)
RALPH_NOW=2020-01-01T00:00:00Z record_signal runtime_failure "vet fails" "gofmt drift" "run gofmt" "" medium >/dev/null
RALPH_NOW=2020-01-01T00:01:00Z signal_resolve "$pk" "ran gofmt on save" >/dev/null
eq "fresh candidate unverified before probation" false "$(jq -r '.verified' "$SKILL_DIR/$pk.json")"
verify_skills   # real now >> 2020 + probation, signal still resolved -> verified
eq "candidate that survived probation is verified" true "$(jq -r '.verified' "$SKILL_DIR/$pk.json")"
aout=$(handle_skill_command approve "$pk" 2>&1)
printf '%s' "$aout" | grep -q 'Approved skill' && ok "verified candidate is approvable via CLI" || bad "verified not approvable: $aout"

export SKILL_DIR="$TMP/vg-skill3"; rm -rf "$SKILL_DIR"; init_skills
q=$(record_skill "some--theme" "prob" "res" "")
RALPH_SKILL_REQUIRE_VERIFY=0 handle_skill_command approve "$q" >/dev/null 2>&1
eq "RALPH_SKILL_REQUIRE_VERIFY=0 bypasses the gate" approved "$(jq -r .status "$SKILL_DIR/$q.json")"
unset RALPH_SKILL_REQUIRE_VERIFY

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
