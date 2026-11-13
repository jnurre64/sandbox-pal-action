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

# ═══════════════════════════════════════════════════════════════
# check-prereqs.sh — optional sandbox profile (#137)
# ═══════════════════════════════════════════════════════════════

@test "check-prereqs: a missing sandbox runtime is reported as optional, not as a failure" {
    run env AGENT_SANDBOX_SRT="${TEST_TEMP_DIR}/nowhere/srt" bash "${SCRIPTS_DIR}/check-prereqs.sh"
    assert_output --partial "sandbox profile (optional) unavailable"
    refute_output --partial "Missing required tools: srt"
}

@test "check-prereqs: a sandbox runtime that cannot start is a warning with its first error line" {
    mkdir -p "${TEST_TEMP_DIR}/bin"
    printf '#!/bin/bash\necho "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted" >&2\nexit 1\n' > "${TEST_TEMP_DIR}/bin/srt"
    local tool
    for tool in bwrap socat rg; do printf '#!/bin/bash\nexit 0\n' > "${TEST_TEMP_DIR}/bin/${tool}"; done
    chmod +x "${TEST_TEMP_DIR}/bin/"*
    run env PATH="${TEST_TEMP_DIR}/bin:${PATH}" AGENT_SANDBOX_SRT= bash "${SCRIPTS_DIR}/check-prereqs.sh"
    assert_output --partial "sandbox runtime is installed but cannot start"
    assert_output --partial "RTM_NEWADDR"
}
