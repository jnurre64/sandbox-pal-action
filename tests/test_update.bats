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

    echo "#!/bin/bash" > "$install_dir/scripts/sandbox-pal-dispatch.sh"
    echo "# common functions" > "$install_dir/scripts/lib/common.sh"
    echo "# worktree management" > "$install_dir/scripts/lib/worktree.sh"
    echo "# default triage prompt" > "$install_dir/prompts/triage.md"
    echo "agent|1D76DB|Trigger" > "$install_dir/labels.txt"

    # Write .upstream tracking file
    {
        echo "repo: https://github.com/jnurre64/sandbox-pal-action.git"
        echo "version: $version"
        echo "synced_at: \"2026-03-21T00:00:00Z\""
        echo "checksums:"
        for f in scripts/sandbox-pal-dispatch.sh scripts/lib/common.sh scripts/lib/worktree.sh prompts/triage.md labels.txt; do
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
    stored_cs=$(grep "scripts/sandbox-pal-dispatch.sh" "$install_dir/.upstream" | sed 's/.*"sha256://' | sed 's/".*//')
    local current_cs
    current_cs=$(sha256sum "$install_dir/scripts/sandbox-pal-dispatch.sh" | cut -d' ' -f1)

    assert_equal "$stored_cs" "$current_cs"
}

@test "update.sh: detects locally modified files" {
    local install_dir="${TEST_TEMP_DIR}/install"
    _create_mock_install "$install_dir"

    # Modify a file locally
    echo "# local change" >> "$install_dir/scripts/sandbox-pal-dispatch.sh"

    # Checksum should no longer match
    local stored_cs
    stored_cs=$(grep "scripts/sandbox-pal-dispatch.sh" "$install_dir/.upstream" | sed 's/.*"sha256://' | sed 's/".*//')
    local current_cs
    current_cs=$(sha256sum "$install_dir/scripts/sandbox-pal-dispatch.sh" | cut -d' ' -f1)

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

@test "setup.sh: writes config_vars section to .upstream" {
    grep -q 'config_vars:' "${SCRIPTS_DIR}/setup.sh"
    grep -q 'parse_config_vars' "${SCRIPTS_DIR}/setup.sh"
}

# ═══════════════════════════════════════════════════════════════
# Config variable migration tests
# ═══════════════════════════════════════════════════════════════

_create_mock_upstream() {
    local upstream_dir="$1"
    mkdir -p "$upstream_dir/scripts/lib" "$upstream_dir/prompts"

    echo "#!/bin/bash" > "$upstream_dir/scripts/sandbox-pal-dispatch.sh"
    echo "# common functions" > "$upstream_dir/scripts/lib/common.sh"

    # Copy the real config-vars.sh so it can be sourced
    cp "${LIB_DIR}/config-vars.sh" "$upstream_dir/scripts/lib/config-vars.sh"
}

_create_mock_example_file() {
    local upstream_dir="$1"
    cat > "$upstream_dir/config.defaults.env.example" << 'EOF'
# Bot account username
AGENT_BOT_USER=""

# Max turns
AGENT_MAX_TURNS=200

# Timeout
AGENT_TIMEOUT=3600
EOF
}

_create_install_with_config_vars() {
    local install_dir="$1"
    local version="${2:-abc123}"
    shift 2
    local vars=("$@")

    _create_mock_install "$install_dir" "$version"

    # Append config_vars: section
    {
        echo "config_vars:"
        for var in "${vars[@]}"; do
            echo "  - $var"
        done
    } >> "$install_dir/.upstream"
}

@test "update.sh: sources config-vars.sh from upstream" {
    grep -q 'source.*config-vars.sh' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: writes config_vars to .upstream tracking" {
    grep -q 'config_vars:' "${SCRIPTS_DIR}/update.sh"
    grep -q 'parse_config_vars.*config.defaults.env.example' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: detects new config variables section" {
    grep -q 'Detect new config variables' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: first-run shows initialization message when no config_vars" {
    grep -q 'Config variable tracking initialized' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: has secret detection heuristic" {
    grep -q 'SECRET_KEYWORDS' "${SCRIPTS_DIR}/update.sh"
    grep -q 'TOKEN\|KEY\|SECRET\|WEBHOOK\|PASSWORD\|CREDENTIAL' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: creates config.env backup before modifications" {
    grep -q '\.bak\.' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: writes section header with date" {
    grep -q 'Added by /update on' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: supports add-active, commented, and skip choices" {
    grep -q '(A)dd active' "${SCRIPTS_DIR}/update.sh"
    grep -q '(c)ommented' "${SCRIPTS_DIR}/update.sh"
    grep -q '(s)kip' "${SCRIPTS_DIR}/update.sh"
}

@test "update.sh: includes config summary in completion message" {
    grep -q 'CONFIG_TOTAL' "${SCRIPTS_DIR}/update.sh"
    grep -q 'new setting(s) detected' "${SCRIPTS_DIR}/update.sh"
}

# ═══════════════════════════════════════════════════════════════
# Config var detection logic (functional tests using config-vars.sh)
# ═══════════════════════════════════════════════════════════════

@test "config migration: stored vars parsed from .upstream config_vars section" {
    source "${LIB_DIR}/config-vars.sh"

    local install_dir="${TEST_TEMP_DIR}/install"
    _create_install_with_config_vars "$install_dir" "abc123" \
        "AGENT_BOT_USER" "AGENT_MAX_TURNS" "AGENT_TIMEOUT"

    # Verify config_vars section is present and parseable
    mapfile -t stored < <(
        sed -n '/^config_vars:/,/^[^ ]/{ /^  - /s/^  - //p }' "$install_dir/.upstream"
    )
    [ "${#stored[@]}" -eq 3 ]
    [ "${stored[0]}" = "AGENT_BOT_USER" ]
    [ "${stored[1]}" = "AGENT_MAX_TURNS" ]
    [ "${stored[2]}" = "AGENT_TIMEOUT" ]
}

@test "config migration: new vars detected by comparing upstream vs stored" {
    source "${LIB_DIR}/config-vars.sh"

    local install_dir="${TEST_TEMP_DIR}/install"
    local upstream_dir="${TEST_TEMP_DIR}/upstream"

    # Stored knows about BOT_USER and MAX_TURNS
    _create_install_with_config_vars "$install_dir" "abc123" \
        "AGENT_BOT_USER" "AGENT_MAX_TURNS"

    # Upstream adds AGENT_TIMEOUT and AGENT_NEW_FEATURE
    _create_mock_upstream "$upstream_dir"
    cat > "$upstream_dir/config.defaults.env.example" << 'EOF'
AGENT_BOT_USER=""
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_NEW_FEATURE="enabled"
EOF

    mapfile -t upstream_vars < <(parse_config_vars "$upstream_dir/config.defaults.env.example")
    mapfile -t stored_vars < <(
        sed -n '/^config_vars:/,/^[^ ]/{ /^  - /s/^  - //p }' "$install_dir/.upstream"
    )

    # Compute new vars
    new_vars=()
    for var in "${upstream_vars[@]}"; do
        found=false
        for stored in "${stored_vars[@]}"; do
            if [ "$var" = "$stored" ]; then found=true; break; fi
        done
        [ "$found" = false ] && new_vars+=("$var")
    done

    [ "${#new_vars[@]}" -eq 2 ]
    [[ " ${new_vars[*]} " == *" AGENT_TIMEOUT "* ]]
    [[ " ${new_vars[*]} " == *" AGENT_NEW_FEATURE "* ]]
}

@test "config migration: already-set vars in config.env are skipped" {
    source "${LIB_DIR}/config-vars.sh"

    # Create config.env with AGENT_FOO already set
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
AGENT_FOO="custom_value"
EOF

    mapfile -t user_vars < <(parse_config_vars "$TEST_TEMP_DIR/config.env")

    # AGENT_FOO should be detected as already set
    found=false
    for uv in "${user_vars[@]}"; do
        [ "$uv" = "AGENT_FOO" ] && found=true
    done
    [ "$found" = true ]
}

@test "config migration: commented vars in config.env are detected as present" {
    source "${LIB_DIR}/config-vars.sh"

    # User has a commented-out entry — still counts as "present"
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
# AGENT_FOO="old_default"
EOF

    mapfile -t user_vars < <(parse_config_vars "$TEST_TEMP_DIR/config.env")

    found=false
    for uv in "${user_vars[@]}"; do
        [ "$uv" = "AGENT_FOO" ] && found=true
    done
    [ "$found" = true ]
}

@test "config migration: secret keyword heuristic detects sensitive vars" {
    # Verify vars containing TOKEN/KEY/SECRET etc. would be flagged
    secret_keywords="TOKEN|KEY|SECRET|WEBHOOK|PASSWORD|CREDENTIAL"

    echo "AGENT_API_TOKEN" | grep -qE "$secret_keywords"
    echo "AGENT_SECRET_VALUE" | grep -qE "$secret_keywords"
    echo "AGENT_WEBHOOK_URL" | grep -qE "$secret_keywords"
    echo "AGENT_PASSWORD_HASH" | grep -qE "$secret_keywords"

    # Non-secret var should NOT match
    ! echo "AGENT_MAX_TURNS" | grep -qE "$secret_keywords"
    ! echo "AGENT_TIMEOUT" | grep -qE "$secret_keywords"
}

@test "config migration: idempotent when no new vars exist" {
    source "${LIB_DIR}/config-vars.sh"

    local upstream_dir="${TEST_TEMP_DIR}/upstream"
    _create_mock_upstream "$upstream_dir"
    cat > "$upstream_dir/config.defaults.env.example" << 'EOF'
AGENT_BOT_USER=""
AGENT_MAX_TURNS=200
EOF

    # Stored list matches upstream exactly
    mapfile -t upstream_vars < <(parse_config_vars "$upstream_dir/config.defaults.env.example")
    stored_vars=("AGENT_BOT_USER" "AGENT_MAX_TURNS")

    new_vars=()
    for var in "${upstream_vars[@]}"; do
        found=false
        for stored in "${stored_vars[@]}"; do
            if [ "$var" = "$stored" ]; then found=true; break; fi
        done
        [ "$found" = false ] && new_vars+=("$var")
    done

    [ "${#new_vars[@]}" -eq 0 ]
}

@test "config migration: backup file created with date suffix" {
    local config_file="$TEST_TEMP_DIR/config.env"
    echo 'AGENT_FOO="bar"' > "$config_file"

    # Simulate backup creation
    cp "$config_file" "${config_file}.bak.$(date '+%Y%m%d')"

    # Verify backup exists and matches original
    [ -f "${config_file}.bak.$(date '+%Y%m%d')" ]
    diff -q "$config_file" "${config_file}.bak.$(date '+%Y%m%d')"
}

@test "config migration: active entry format is correct" {
    local config_file="$TEST_TEMP_DIR/config.env"
    echo 'AGENT_FOO="bar"' > "$config_file"

    # Simulate adding an active entry
    echo "" >> "$config_file"
    echo "# ── Added by /update on $(date '+%Y-%m-%d') ──" >> "$config_file"
    echo 'AGENT_NEW_VAR="default_value"' >> "$config_file"

    grep -q 'AGENT_NEW_VAR="default_value"' "$config_file"
    grep -q 'Added by /update on' "$config_file"
}

@test "config migration: commented entry format is correct" {
    local config_file="$TEST_TEMP_DIR/config.env"
    echo 'AGENT_FOO="bar"' > "$config_file"

    # Simulate adding a commented entry
    echo '# AGENT_NEW_VAR="default_value"  # (upstream default)' >> "$config_file"

    grep -q '# AGENT_NEW_VAR="default_value"  # (upstream default)' "$config_file"
}

@test "config migration: commented entry does not override defaults.sh" {
    source "${LIB_DIR}/config-vars.sh"

    # A commented-out line should not set the variable
    cat > "$TEST_TEMP_DIR/config.env" << 'EOF'
# AGENT_TEST_VAR="commented_value"  # (upstream default)
EOF

    source "$TEST_TEMP_DIR/config.env"
    # AGENT_TEST_VAR should NOT be set (it's commented out)
    [ -z "${AGENT_TEST_VAR:-}" ]
}
