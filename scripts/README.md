# scripts/ — small `gh` workflow helpers

A tiny library so polling a repo/PR and closing out a review cost a few tokens instead of a wall
of inline `gh api graphql … --jq …`. Every script reads the **current** repo's GitHub remote by
default; pass `owner/repo` to target another. All require an authenticated `gh` (and `jq`). Run them
as `scripts/<name>`.

### Status & polling (read-only)
| Script | What it does |
|--------|--------------|
| `pr-status <pr> [owner/repo]` | One-glance PR status: `state` / `mergeable` / `reviewDecision`, reviewers, and each **unresolved** review thread as `<threadId>  path:line  comment…` (truncated) |
| `pr-review <pr> [owner/repo]` | The **full, untruncated** bodies of the unresolved review comments — what you read to actually address them |
| `pr-checks [pr] [owner/repo]` | CI check rollup for a PR (or the current branch) — wraps `gh pr checks` |
| `pr-wait <pr> [owner/repo] [max_seconds=180]` | Polls until the PR has a review (e.g. gemini-code-assist) or times out, then prints `pr-status` |
| `repo-health [owner/repo]` | One-line rollup: open PRs / recent failing CI / open Dependabot, code-scanning, secret-scanning alerts (`n/a` when a feature is off) |
| `ci-fails [owner/repo] [limit=10]` | Recent failing CI runs as `<run-id>  <workflow>  [branch]  <url>` — feed a run id into `ralph triage --fix-ci --run <id>` |

### Review close-out (writes)
| Script | What it does |
|--------|--------------|
| `resolve-thread <threadId> [reply]` | Reply to (optional) + mark one review thread resolved |
| `pr-resolve-all <pr> [reply] [owner/repo]` | Resolve **every** unresolved thread on a PR (run after you've addressed them) |
| `pr-merge <pr> [owner/repo]` | Merge the PR, delete its branch, and (for the current repo) sync the local default branch |


### Public org automation
| Script | What it does |
|--------|--------------|
| `org-public-targets --org ORG [--write FILE]` | Discover active public org repos through `gh repo list` and emit an `owner/repo` allowlist for Ralph triage |
| `org-patrol --org ORG [--mode report]` | Refresh the public allowlist, run a Synapse live-test, run Ralph triage, and record compact resource history across the org; defaults to read-only report mode |
| `org-soak-summary --org ORG [--json]` | Summarize org-patrol `soak-summary.jsonl` into cycle counts, failure counts, worst monotonic elapsed time, worst wall-clock elapsed time, legacy elapsed record count, last resource band, and recent Synapse rc values |
| `org-install-systemd install --org ORG [--interval 30min] [--cpu-quota 25%] [--memory-max 1G] [--io-weight 100]` | Install/enable a user systemd timer for `org-patrol`; config goes in `~/.config/ralph/<org>-patrol.env`, optional limits write systemd CPU/memory/IO controls, and Synapse checking defaults off until the local DB app role is RLS-safe |

Patrol modes are `report`, `suggest`, `suggest-apply`, `fix-ci`, `fix-ci-apply`, `fix-security`, and `fix-security-apply`. Only the `*-apply` modes write to GitHub, and code-changing modes still use `ralph/fix-*` branches. Resource history is local JSONL under the patrol log directory by default, supports growth/slope warning budgets through `RALPH_RESOURCE_*`, and prints a compact `ralph resource summary` band (`normal`, `warning`, or `sustained-growth`) in each patrol log; `ralph resource summary --json` exposes the same band for tools. It can be disabled with `--no-resource-history` or `RALPH_ORG_RESOURCE_HISTORY=0`. Patrols also append durable mode-`600` soak evidence to `soak-summary.jsonl` by default, including exit status, monotonic elapsed time, wall-clock elapsed diagnostics, target count, Synapse rc, triage rc, resource band/warnings, and patrol log path; disable with `--no-soak-summary` or `RALPH_ORG_SOAK_SUMMARY=0`. Use `org-soak-summary` to convert those rows into a compact text or JSON rollup. The `resq-*` script names are compatibility wrappers for the historical resq-software deployment.

### Dev
| Script | What it does |
|--------|--------------|
| `run-tests` | Run the full suite (`tests/run_all.sh`) and print the rollup + total case count |
| `bd-sync-compat` | Compatibility wrapper for session close-out: uses `bd sync` when available, otherwise `bd backup sync`, `bd vc commit`, or a clean skip |

### The review close-out loop, end to end
```bash
scripts/pr-wait 34                       # wait for the reviewer, then show status
scripts/pr-review 34                     # read the full comments
# …address them, push…
scripts/pr-resolve-all 34 "Addressed in <sha>."
scripts/pr-merge 34                      # merge + delete branch + sync main
```
