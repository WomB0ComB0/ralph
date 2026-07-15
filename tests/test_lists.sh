#!/bin/bash
# TDD harness for configurable excludes (hash excludes + gitdiff-exclude resolver).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/tools.sh"   # compute_project_hash + _project_files_mtime

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
has()  { grep -qxF "$2" <<<"$1"; }   # $1 multiline list contains exact line $2

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== hash_exclude_names: defaults =="
out=$(hash_exclude_names "$TMP/none")
has "$out" "node_modules" && ok "defaults include node_modules" || bad "missing node_modules"
has "$out" ".git"         && ok "defaults include .git"         || bad "missing .git"
has "$out" "__pycache__"  && ok "defaults include __pycache__"  || bad "missing __pycache__"
# home-dir cruft must be GONE
if has "$out" "Downloads" || has "$out" "Pictures" || has "$out" "VirtualBox VMs" || has "$out" "Music"; then
  bad "home-dir cruft still present"
else ok "home-dir cruft removed"; fi

echo "== hash_exclude_names: env override (IFS-robust) =="
IFS=$'\n\t'  # simulate engine.sh runtime IFS
out=$(RALPH_HASH_EXCLUDES="foodir, bardir baz_dir" hash_exclude_names "$TMP/none")
IFS=$' \t\n'
has "$out" "foodir" && has "$out" "bardir" && has "$out" "baz_dir" && ok "env adds names (comma/space split under restrictive IFS)" || bad "env split failed"
has "$out" "node_modules" && ok "env extends (keeps defaults)" || bad "env replaced defaults"

echo "== hash_exclude_names: file override + dedup =="
printf '# comment\nmy_artifacts\n\nnode_modules\n  spaced_dir  \n' > "$TMP/excludes"
out=$(hash_exclude_names "$TMP/excludes")
has "$out" "my_artifacts" && ok "file adds names" || bad "file names missing"
has "$out" "spaced_dir"   && ok "file trims whitespace" || bad "whitespace not trimmed"
[[ "$(grep -cxF node_modules <<<"$out")" == "1" ]] && ok "dedup keeps node_modules once" || bad "dedup failed"

echo "== resolve_gitdiff_exclude: precedence =="
( export GITDIFF_EXCLUDE="/explicit/path"; [[ "$(resolve_gitdiff_exclude "$TMP")" == "/explicit/path" ]] ) \
  && ok "explicit env wins" || bad "env precedence"
mkdir -p "$TMP/proj"; : > "$TMP/proj/gitdiff-exclude"
( unset GITDIFF_EXCLUDE; [[ "$(resolve_gitdiff_exclude "$TMP/proj")" == "$TMP/proj/gitdiff-exclude" ]] ) \
  && ok "repo-root gitdiff-exclude is the default" || bad "repo default"
# Isolate HOME so the user/CI-runner's real ~/.config/git/gitdiff-exclude fallback
# can't turn "no file anywhere" into a non-empty result (test must be hermetic).
( unset GITDIFF_EXCLUDE; HOME="$TMP/empty-home"; [[ -z "$(resolve_gitdiff_exclude "$TMP/empty")" ]] ) \
  && ok "no file -> empty" || bad "empty case"

echo "== compute_project_hash: UNCOMMITTED changes invalidate the cache (lazy-detection) =="
# Isolate the hash cache under a temp HOME so this doesn't read/pollute the real cache.
_OLDHOME="$HOME"; HPHASH=$(mktemp -d); export HOME="$HPHASH"
HPROJ=$(mktemp -d)
( cd "$HPROJ" && git init -q && git config user.email a@a && git config user.name a \
    && echo seed > a.txt && git add -A && git commit -qm seed ) >/dev/null 2>&1
# The loop runs with cwd == PROJECT_DIR (git ls-files | xargs md5 needs that); mirror it.
_OLDPWD="$PWD"; cd "$HPROJ" || true
PROJECT_DIR="$HPROJ"
hh1=$(compute_project_hash 2>/dev/null)
hh1b=$(compute_project_hash 2>/dev/null)
[[ -n "$hh1" && "$hh1" != "d41d8cd98f00b204e9800998ecf8427e" ]] && ok "compute_project_hash hashes the files" || bad "empty/null hash: $hh1"
eq "stable hash when nothing changes (cache hit)" "$hh1" "$hh1b"
# The bug: an uncommitted new file left the git-path cache valid (keyed on commit time) ->
# the SAME stale hash -> false 'no files modified'. After the fix it must change.
sleep 1; echo created-by-agent > "$HPROJ/uncommitted.js"
hh2=$(compute_project_hash 2>/dev/null)
[[ -n "$hh2" && "$hh2" != "$hh1" ]] && ok "uncommitted new file changes the hash (cache invalidated)" || bad "stale hash: uncommitted file undetected (h1=$hh1 h2=$hh2)"
cd "$_OLDPWD" || true
export HOME="$_OLDHOME"; rm -rf "$HPHASH" "$HPROJ"; unset PROJECT_DIR

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
