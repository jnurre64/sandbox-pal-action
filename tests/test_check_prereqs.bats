#!/usr/bin/env bats
# Tests for scripts/check-test-prereqs.sh

load 'helpers/test_helper'

# ═══════════════════════════════════════════════════════════════
# Platform detection
# ═══════════════════════════════════════════════════════════════

@test "check-test-prereqs: detects platform" {
    run bash "${SCRIPTS_DIR}/check-test-prereqs.sh"
    assert_output --partial "Platform:"
}

# ═══════════════════════════════════════════════════════════════
# Tool detection — all present
# ═══════════════════════════════════════════════════════════════

@test "check-test-prereqs: exits 0 when all tools are present" {
    # Only run if tools are actually present on this system
    if ! command -v jq &>/dev/null || ! command -v shellcheck &>/dev/null; then
        skip "jq or shellcheck not installed on this system"
    fi
    if [ ! -x "${SCRIPTS_DIR}/../tests/bats/bin/bats" ]; then
        skip "bats submodule not initialized"
    fi

    run bash "${SCRIPTS_DIR}/check-test-prereqs.sh"
    assert_success
    assert_output --partial "All test prerequisites met"
}

# ═══════════════════════════════════════════════════════════════
# Tool detection — missing tools
# ═══════════════════════════════════════════════════════════════

@test "check-test-prereqs: exits 1 when a required tool is missing" {
    # Use a minimal PATH that won't have jq or shellcheck
    # Keep only basic system dirs so bash itself works
    run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "${SCRIPTS_DIR}/check-test-prereqs.sh"
    if [ "$status" -eq 0 ]; then
        skip "all tools found even in restricted PATH"
    fi
    assert_failure
}

@test "check-test-prereqs: reports missing tool with install instructions" {
    run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "${SCRIPTS_DIR}/check-test-prereqs.sh"
    if [ "$status" -eq 0 ]; then
        skip "all tools found in restricted PATH"
    fi
    assert_failure
    # Should contain install instructions
    assert_output --partial "Install"
}

@test "check-test-prereqs: names the missing tool in output" {
    run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "${SCRIPTS_DIR}/check-test-prereqs.sh"
    if [ "$status" -eq 0 ]; then
        skip "all tools found in restricted PATH"
    fi
    assert_failure
    # Should name at least one missing tool
    assert_output --partial "not found"
}

# ═══════════════════════════════════════════════════════════════
# grep -P (PCRE) detection
# ═══════════════════════════════════════════════════════════════

@test "check-test-prereqs: checks for grep -P support" {
    run bash "${SCRIPTS_DIR}/check-test-prereqs.sh"
    # Output should mention PCRE regardless of whether it's supported or not
    assert_output --partial "grep -P"
}

# ═══════════════════════════════════════════════════════════════
# Bats submodule detection
# ═══════════════════════════════════════════════════════════════

@test "check-test-prereqs: detects missing bats submodule" {
    # Copy script to a temp location so it looks for bats relative to itself
    local fake_scripts="${TEST_TEMP_DIR}/scripts"
    mkdir -p "$fake_scripts"
    cp "${SCRIPTS_DIR}/check-test-prereqs.sh" "$fake_scripts/"

    run bash "$fake_scripts/check-test-prereqs.sh"
    assert_failure
    assert_output --partial "bats"
}
