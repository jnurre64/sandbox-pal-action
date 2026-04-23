# Scripts

## Entry Point

`sandbox-pal-dispatch.sh` is the main entry point. It takes `<event_type> <repo> <number>` and dispatches to one of four handler functions: `handle_new_issue`, `handle_issue_reply`, `handle_implement`, `handle_pr_review`.

## Sourcing Chain

`sandbox-pal-dispatch.sh` loads config, then sources all `lib/` modules in order: `common.sh`, `worktree.sh`, `data-fetch.sh`, `notify.sh`. All functions from lib/ are available globally after sourcing.

## Config Loading Order

1. `config.defaults.env` (committed project defaults)
2. `config.env` (gitignored sensitive overrides)
3. `lib/defaults.sh` (fills in anything still unset)

Environment variables always take highest precedence.

## Conventions

- `set -euo pipefail` in all scripts
- Must pass `shellcheck` with zero warnings
- Functions use globals `REPO`, `NUMBER`, `EVENT_TYPE`, `WORKTREE_DIR`, `BRANCH_NAME` set by the entry point
- Issue content is passed via environment variables (never shell-interpolated)
