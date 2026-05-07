#!/usr/bin/env bats
# Guard: bot install scripts must change to their own directory before
# `pip install`, or the editable `-e ../shared` requirement is resolved
# against the caller's cwd and pip rejects it as "not a valid editable
# requirement". Bug surfaced when re-running install.sh from outside the
# bot directory; both Discord and Slack install scripts had the same defect.

load 'helpers/test_helper'

# shellcheck disable=SC2154
@test "REGRESSION: discord-bot/install.sh cds into SCRIPT_DIR before pip install" {
    local script="${TEST_ROOT}/../discord-bot/install.sh"
    [ -f "$script" ] || fail "discord-bot/install.sh not found"

    local pip_line
    pip_line=$(grep -n 'pip" install' "$script" | head -1 | cut -d: -f1)
    [ -n "$pip_line" ] || fail "no 'pip install' line found in discord-bot/install.sh"

    if ! sed -n "1,${pip_line}p" "$script" | grep -qE '^[[:space:]]*cd[[:space:]]+"\$\{?SCRIPT_DIR\}?"'; then
        fail "discord-bot/install.sh: missing 'cd \"\$SCRIPT_DIR\"' before pip install at line ${pip_line}"
    fi
}

# shellcheck disable=SC2154
@test "REGRESSION: slack-bot/install.sh cds into SCRIPT_DIR before pip install" {
    local script="${TEST_ROOT}/../slack-bot/install.sh"
    [ -f "$script" ] || fail "slack-bot/install.sh not found"

    local pip_line
    pip_line=$(grep -n 'pip" install' "$script" | head -1 | cut -d: -f1)
    [ -n "$pip_line" ] || fail "no 'pip install' line found in slack-bot/install.sh"

    if ! sed -n "1,${pip_line}p" "$script" | grep -qE '^[[:space:]]*cd[[:space:]]+"\$\{?SCRIPT_DIR\}?"'; then
        fail "slack-bot/install.sh: missing 'cd \"\$SCRIPT_DIR\"' before pip install at line ${pip_line}"
    fi
}

# Both bot install scripts must accept `--config <path>` for non-interactive use.
# Without it, scripted re-installs (after the rename, after CI, after this very
# test) have to fall back to feeding `read` via stdin, which is fragile and
# diverges between the two bots. Asserts the option-parsing block exists.
# shellcheck disable=SC2154
@test "discord-bot/install.sh accepts --config <path> non-interactively" {
    local script="${TEST_ROOT}/../discord-bot/install.sh"
    [ -f "$script" ] || fail "discord-bot/install.sh not found"

    grep -qE '^[[:space:]]*--config\)' "$script" || \
        fail "discord-bot/install.sh: missing '--config' case in option parser"
}

# shellcheck disable=SC2154
@test "slack-bot/install.sh accepts --config <path> non-interactively" {
    local script="${TEST_ROOT}/../slack-bot/install.sh"
    [ -f "$script" ] || fail "slack-bot/install.sh not found"

    grep -qE '^[[:space:]]*--config\)' "$script" || \
        fail "slack-bot/install.sh: missing '--config' case in option parser"
}
