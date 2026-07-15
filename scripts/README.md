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
