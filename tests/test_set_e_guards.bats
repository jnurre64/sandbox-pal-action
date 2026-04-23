#!/usr/bin/env bats
# Guard: every triage-JSON extraction site must be wrapped in set +e / set -e.
# Without the guard, a grep match failure under set -euo pipefail kills the
# script before the graceful fallback path can execute.

load 'helpers/test_helper'

# shellcheck disable=SC2154
@test "REGRESSION v0.1.0: all triage-JSON extraction sites have set +e guard" {
    local script="${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"

    # Find all line numbers with the JSON extraction pattern
    local extraction_lines
    extraction_lines=$(grep -n 'grep -oE.*\[{].*action.*\[}]' "$script" | cut -d: -f1)

    [ -n "$extraction_lines" ] || fail "No JSON extraction sites found — pattern may have changed"

    local missing=()
    for line_num in $extraction_lines; do
        # Check that 'set +e' appears within 3 lines before the extraction
        local start=$((line_num - 3))
        [ "$start" -lt 1 ] && start=1
        if ! sed -n "${start},${line_num}p" "$script" | grep -q 'set +e'; then
            missing+=("line $line_num")
        fi
    done

    [ ${#missing[@]} -eq 0 ] || fail "JSON extraction sites missing set +e guard: ${missing[*]}"
}
