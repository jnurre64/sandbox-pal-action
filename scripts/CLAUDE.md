# Scripts

## Entry Point

`sandbox-pal-dispatch.sh` is the main entry point. It takes `<event_type> <repo> <number>` and dispatches to one of four handler functions: `handle_new_issue`, `handle_issue_reply`, `handle_implement`, `handle_pr_review`.

## Sourcing Chain

`sandbox-pal-dispatch.sh` loads config, then sources all `lib/` modules in order: `common.sh`, `worktree.sh`, `data-fetch.sh`, `notify.sh`. All functions from lib/ are available globally after sourcing.

## Config Loading Order

1. `config.defaults.env` (committed project defaults)
2. `config.env` (gitignored sensitive overrides)
3. `lib/defaults.sh` (fills in anything still unset)

An exported environment variable survives a file only when the file assigns it as `VAR="${VAR:-default}"`. A plain `VAR=value` overwrites it. `lib/config-load.sh` records each exported `AGENT_*` variable a file overwrote, and startup logs them as a `WARN` (names only).

## Conventions

- `set -euo pipefail` in all scripts
- Must pass `shellcheck` with zero warnings
- Functions use globals `REPO`, `NUMBER`, `EVENT_TYPE`, `WORKTREE_DIR`, `BRANCH_NAME` set by the entry point
- Issue content reaches a phase as files under `.agent-data/context/` (`lib/phase-context.sh`), written before every launch; it is never shell-interpolated. The matching `AGENT_*` exports are kept for older custom prompts
- Claude phases get their permission rules from a generated `--settings` file (`engine_claude_settings`), not from `--allowedTools`
