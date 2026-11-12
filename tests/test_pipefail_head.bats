#!/usr/bin/env bats
# Tests for #129: `producer | head -N` under `set -o pipefail`. Once the
# producer has more to write than head takes, it dies of SIGPIPE and the
# pipeline exits 141, which `set -e` and the ERR trap report as an
# infrastructure error. Limit at the source instead of piping into head.

load 'helpers/test_helper'

# A repository whose HEAD is $1 commits ahead of origin/main.
_repo_ahead_by() {
    local count="$1" i
    WORKTREE_DIR="${TEST_TEMP_DIR}/repo"
    export WORKTREE_DIR
    git init -q "$WORKTREE_DIR"
    {
        printf 'commit refs/heads/work\ncommitter T <t@example.invalid> 1700000000 +0000\ndata 5\nroot\n\n'
        printf 'reset refs/remotes/origin/main\nfrom refs/heads/work\n\n'
        for ((i = 1; i <= count; i++)); do
            printf 'commit refs/heads/work\ncommitter T <t@example.invalid> %d +0000\ndata <<MSG\ncommit %d\nMSG\n\n' \
                "$((1700000000 + i))" "$i"
        done
    } | git -C "$WORKTREE_DIR" fast-import --quiet
    git -C "$WORKTREE_DIR" symbolic-ref HEAD refs/heads/work
}

@test "REGRESSION v1.3.0: branch_commit_lines survives pipefail on a branch with more commits than the limit" {
    _repo_ahead_by 5000

    run bash -c "set -euo pipefail; source '${LIB_DIR}/common.sh'; lines=\$(branch_commit_lines 30 '%h %s'); printf '%s\n' \"\$lines\""

    assert_success
    assert_equal "${#lines[@]}" 30
    assert_line --index 0 --regexp '^[0-9a-f]+ commit 5000$'
}

@test "branch_commit_lines: returns nothing, successfully, when origin/main is missing" {
    WORKTREE_DIR="${TEST_TEMP_DIR}/empty"
    export WORKTREE_DIR
    git init -q "$WORKTREE_DIR"

    run bash -c "set -euo pipefail; source '${LIB_DIR}/common.sh'; branch_commit_lines 20 '- %s'"

    assert_success
    assert_output ""
}

@test "REGRESSION v1.3.0: both commit-log sites limit through branch_commit_lines" {
    grep -q "commit_history=\$(branch_commit_lines 30 '%h %s')" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "commit_log=\$(branch_commit_lines 20 '- %s')" "${LIB_DIR}/common.sh"
}

@test "guard: no script pipes into head" {
    # Every dispatch script runs under pipefail. Use the producer's own limit
    # (`git log -n`, `grep -m`), `sed -n 1p`, or a parameter expansion.
    run grep -rnE '\|[[:space:]]*head([[:space:]]|$)' "${SCRIPTS_DIR}/" --include="*.sh"
    assert_failure
}
