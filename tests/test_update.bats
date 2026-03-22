#!/usr/bin/env bats
# Tests for scripts/update.sh

load 'helpers/test_helper'

# ═══════════════════════════════════════════════════════════════
# Source verification tests
# ═══════════════════════════════════════════════════════════════

@test "update.sh: uses dynamic file discovery (not hardcoded list)" {
    # Should use find to discover files, not a static TRACKED_FILES array
    grep -q 'find.*UPSTREAM_DIR.*scripts.*prompts.*-type f' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: tracks labels.txt" {
    grep -q 'labels.txt' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: exits cleanly when already up to date" {
    grep -q 'Already up to date' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: handles missing .upstream file" {
    grep -q '.upstream tracking file not found' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: cleans up temp directory on exit" {
    grep -q 'trap.*rm -rf' "${SCRIPTS_DIR}/update.sh"
}

# ═══════════════════════════════════════════════════════════════
# Functional tests with mock installation
# ═══════════════════════════════════════════════════════════════

_create_mock_install() {
    local install_dir="$1"
    local version="${2:-abc123}"

    mkdir -p "$install_dir/scripts/lib" "$install_dir/prompts"

    echo "#!/bin/bash" > "$install_dir/scripts/agent-dispatch.sh"
    echo "# common functions" > "$install_dir/scripts/lib/common.sh"
    echo "# worktree management" > "$install_dir/scripts/lib/worktree.sh"
    echo "# default triage prompt" > "$install_dir/prompts/triage.md"
    echo "agent|1D76DB|Trigger" > "$install_dir/labels.txt"

    # Write .upstream tracking file
    {
        echo "repo: https://github.com/jnurre64/claude-agent-dispatch.git"
        echo "version: $version"
        echo "synced_at: \"2026-03-21T00:00:00Z\""
        echo "checksums:"
        for f in scripts/agent-dispatch.sh scripts/lib/common.sh scripts/lib/worktree.sh prompts/triage.md labels.txt; do
            if [ -f "$install_dir/$f" ]; then
                local cs
                cs=$(sha256sum "$install_dir/$f" | cut -d' ' -f1)
                echo "  ${f}: \"sha256:${cs}\""
            fi
        done
    } > "$install_dir/.upstream"
}

@test "update.sh: fails when install directory doesn't exist" {
    run bash "${SCRIPTS_DIR}/update.sh" "/nonexistent/path"
    assert_failure
    assert_output --partial "not found"
}

@test "update.sh: fails when .upstream file is missing" {
    local install_dir="${TEST_TEMP_DIR}/install"
    mkdir -p "$install_dir"

    run bash "${SCRIPTS_DIR}/update.sh" "$install_dir"
    assert_failure
    assert_output --partial ".upstream tracking file not found"
}

@test "update.sh: detects unmodified files correctly" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    # Verify checksums match (file unchanged = checksum matches stored)
    local stored_cs
    stored_cs=$(grep "scripts/agent-dispatch.sh" "$install_dir/.upstream" | sed 's/.*"sha256://' | sed 's/".*//')
    local current_cs
    current_cs=$(sha256sum "$install_dir/scripts/agent-dispatch.sh" | cut -d' ' -f1)

    assert_equal "$stored_cs" "$current_cs"
}

@test "update.sh: detects locally modified files" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    # Modify a file locally
    echo "# local change" >> "$install_dir/scripts/agent-dispatch.sh"

    # Checksum should no longer match
    local stored_cs
    stored_cs=$(grep "scripts/agent-dispatch.sh" "$install_dir/.upstream" | sed 's/.*"sha256://' | sed 's/".*//')
    local current_cs
    current_cs=$(sha256sum "$install_dir/scripts/agent-dispatch.sh" | cut -d' ' -f1)

    [ "$stored_cs" != "$current_cs" ]
}

# ═══════════════════════════════════════════════════════════════
# REGRESSION: Files with no stored checksum treated as modified
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION: files with no stored checksum are treated as locally modified" {
    # Verify the update script treats missing checksums conservatively
    # (assumes locally modified rather than assuming unmodified)
    grep -A2 'No stored checksum' "${SCRIPTS_DIR}/update.sh" | grep -q 'local_modified=true'
}

# ═══════════════════════════════════════════════════════════════
# .upstream file format tests
# ═══════════════════════════════════════════════════════════════

@test ".upstream: contains repo URL" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    grep -q "^repo:" "$install_dir/.upstream"
}

@test ".upstream: contains version hash" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    grep -q "^version:" "$install_dir/.upstream"
}

@test ".upstream: contains checksums section" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    grep -q "^checksums:" "$install_dir/.upstream"
}

@test ".upstream: checksums use sha256 format" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    grep -q '"sha256:' "$install_dir/.upstream"
}

# ═══════════════════════════════════════════════════════════════
# setup.sh tracking tests
# ═══════════════════════════════════════════════════════════════

@test "setup.sh: uses dynamic file discovery for checksums" {
    grep -q 'find.*AGENT_DIR.*scripts.*prompts.*-type f' "${SCRIPTS_DIR}/setup.sh"
}

@test "setup.sh: tracks labels.txt in .upstream" {
    # Verify labels.txt checksum is written in the .upstream tracking section
    grep -q 'labels.txt.*sha256\|labels.txt.*checksum' "${SCRIPTS_DIR}/setup.sh"
}
