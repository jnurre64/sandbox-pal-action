#!/usr/bin/env bats
# Portability guards: fail on known non-portable constructs.
# Uses only POSIX / ERE tools so the guards themselves run everywhere.

load 'helpers/test_helper'

# shellcheck disable=SC2154
@test "portability: no owned shell file uses grep -P (non-portable PCRE mode)" {
    local repo_root
    repo_root="$(cd "${SCRIPTS_DIR}/.." && pwd)"

    # Scope: owned shell surface only.
    #   - scripts/  (all .sh)
    #   - discord-bot/*.sh
    #   - tests/*.bats  (our BATS files themselves)
    # Excluded:
    #   - tests/bats/      upstream BATS submodule
    #   - .worktrees/      transient worktree copies
    #   - docs/            historical plans legitimately reference the flag
    local matches
    matches=$(grep -rnE 'grep[[:space:]]+-[a-zA-Z]*P' \
        "${repo_root}/scripts" \
        "${repo_root}/discord-bot" \
        "${repo_root}/tests"/*.bats 2>/dev/null \
        | grep -v 'test_portability\.bats' || true)

    if [ -n "$matches" ]; then
        echo "Found non-portable 'grep -P' usage:" >&2
        echo "$matches" >&2
        echo "" >&2
        echo "grep -P (PCRE) fails on non-UTF-8 locales (Windows Git Bash default)." >&2
        echo "Rewrite with grep -E, sed -nE, or bash [[ =~ ]]." >&2
        false
    fi
}
