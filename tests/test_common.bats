#!/usr/bin/env bats
# Tests for scripts/lib/common.sh

load 'helpers/test_helper'

# Helper to source common.sh with all required vars set
_source_common() {
    source "${LIB_DIR}/common.sh"
}

# ═══════════════════════════════════════════════════════════════
# load_prompt tests
# ═══════════════════════════════════════════════════════════════

@test "load_prompt: loads custom prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/my-prompt.md"
    echo "Custom triage prompt" > "$prompt_file"

    run load_prompt "triage" "$prompt_file"
    assert_success
    assert_output "Custom triage prompt"
}

@test "load_prompt: falls back to default prompt when custom path is empty" {
    _source_common
    run load_prompt "triage" ""
    assert_success
    [ -n "$output" ]
}

@test "load_prompt: falls back to default prompt when custom file doesn't exist" {
    _source_common
    run load_prompt "triage" "/nonexistent/path.md"
    assert_success
    [ -n "$output" ]
}

# ─── REGRESSION: v1.0.1 — Prompt path resolution ────────────────

@test "REGRESSION v1.0.1: load_prompt resolves relative paths against CONFIG_DIR" {
    mkdir -p "${MOCK_CONFIG_DIR}/prompts"
    echo "Config-relative prompt" > "${MOCK_CONFIG_DIR}/prompts/triage.md"
    export CONFIG_DIR="$MOCK_CONFIG_DIR"

    _source_common
    run load_prompt "triage" "prompts/triage.md"
    assert_success
    assert_output "Config-relative prompt"
}

@test "REGRESSION v1.0.1: load_prompt works with absolute paths regardless of CONFIG_DIR" {
    local prompt_file="${TEST_TEMP_DIR}/absolute-prompt.md"
    echo "Absolute path prompt" > "$prompt_file"
    export CONFIG_DIR="/some/other/dir"

    _source_common
    run load_prompt "triage" "$prompt_file"
    assert_success
    assert_output "Absolute path prompt"
}

@test "REGRESSION v1.0.1: load_prompt falls back when CONFIG_DIR is empty and relative path given" {
    export CONFIG_DIR=""
    _source_common

    # Relative path can't resolve without CONFIG_DIR, should fall back to default
    run load_prompt "triage" "prompts/triage.md"
    assert_success
    [ -n "$output" ]
}

# ═══════════════════════════════════════════════════════════════
# get_implementation_tools tests
# ═══════════════════════════════════════════════════════════════

@test "get_implementation_tools: returns base tools when no extras" {
    export AGENT_EXTRA_TOOLS=""
    LABEL_EXTRA_TOOLS=""
    _source_common

    run get_implementation_tools
    assert_output "$AGENT_ALLOWED_TOOLS_IMPLEMENT"
}

@test "get_implementation_tools: appends AGENT_EXTRA_TOOLS" {
    export AGENT_EXTRA_TOOLS="Bash(npm:*)"
    LABEL_EXTRA_TOOLS=""
    _source_common

    run get_implementation_tools
    assert_output --partial "Bash(npm:*)"
}

@test "get_implementation_tools: appends LABEL_EXTRA_TOOLS" {
    export AGENT_EXTRA_TOOLS=""
    _source_common
    LABEL_EXTRA_TOOLS="Bash(curl:*),Bash(python3:*)"

    run get_implementation_tools
    assert_output --partial "Bash(curl:*)"
    assert_output --partial "Bash(python3:*)"
}

# ═══════════════════════════════════════════════════════════════
# detect_label_tools tests
# ═══════════════════════════════════════════════════════════════

@test "detect_label_tools: sets LABEL_EXTRA_TOOLS when matching label found" {
    create_mock "gh" "agent:image-gen"
    export AGENT_LABEL_TOOLS_agent_image_gen="Bash(curl:*),Bash(python3:*)"
    _source_common

    detect_label_tools
    assert_equal "$LABEL_EXTRA_TOOLS" "Bash(curl:*),Bash(python3:*)"
}

@test "detect_label_tools: LABEL_EXTRA_TOOLS empty when no matching labels" {
    create_mock "gh" "agent:triage"
    _source_common

    detect_label_tools
    assert_equal "$LABEL_EXTRA_TOOLS" ""
}

# ═══════════════════════════════════════════════════════════════
# parse_claude_output tests
# ═══════════════════════════════════════════════════════════════

@test "parse_claude_output: extracts result from json" {
    _source_common
    run parse_claude_output '{"result":"Hello from Claude","session_id":"abc"}'
    assert_output "Hello from Claude"
}

@test "parse_claude_output: extracts result_text on error" {
    _source_common
    run parse_claude_output '{"result_text":"Max turns reached","subtype":"error_max_turns"}'
    assert_output "Max turns reached"
}

@test "parse_claude_output: returns subtype when no result fields" {
    _source_common
    run parse_claude_output '{"subtype":"error_max_turns"}'
    assert_output "Agent stopped: error_max_turns"
}

@test "parse_claude_output: returns raw input when not json" {
    _source_common
    run parse_claude_output "plain text output"
    assert_output "plain text output"
}

@test "REGRESSION v1.2.0: parse_claude_output reports API error when is_error is true despite subtype success" {
    _source_common
    run parse_claude_output '{"is_error":true,"subtype":"success"}'
    refute_output --partial "Agent stopped: success"
    assert_output --partial "API error"
}

@test "parse_claude_output: is_error envelope includes the result detail when present" {
    _source_common
    run parse_claude_output '{"is_error":true,"subtype":"success","result":"API Error: 529 overloaded"}'
    assert_output --partial "API error"
    assert_output --partial "529 overloaded"
}

@test "parse_claude_output: never interpolates a non-error subtype as a cause" {
    _source_common
    run parse_claude_output '{"subtype":"success"}'
    refute_output --partial "Agent stopped: success"
}

# ═══════════════════════════════════════════════════════════════
# redact_secrets tests (#91)
# ═══════════════════════════════════════════════════════════════

@test "redact_secrets: scrubs classic ghp_ token shapes" {
    _source_common
    run redact_secrets <<< "denied: curl -H ghp_abcdefghijklmnopqrstuvwxyz1234 done"
    assert_output --partial "[REDACTED_TOKEN]"
    refute_output --partial "ghp_abcdefghijklmnopqrstuvwxyz1234"
}

@test "redact_secrets: scrubs fine-grained github_pat_ token shapes" {
    _source_common
    run redact_secrets <<< "github_pat_11ABCDEFG0abcdefghijklmnopqrstuv leaked"
    assert_output --partial "[REDACTED_TOKEN]"
    refute_output --partial "github_pat_11ABCDEFG0abcdefghijklmnopqrstuv"
}

@test "redact_secrets: scrubs the value after an Authorization header" {
    _source_common
    run redact_secrets <<< 'curl -H "Authorization: bearer sekrit-value-123" https://x'
    refute_output --partial "sekrit-value-123"
    assert_output --partial "Authorization: bearer [REDACTED]"
}

@test "redact_secrets: scrubs the literal value of credential-looking env vars" {
    _source_common
    export FAKE_AGENT_TOKEN="supersecretvalue123"
    run redact_secrets <<< "the agent typed supersecretvalue123 into a command"
    refute_output --partial "supersecretvalue123"
    assert_output --partial "[REDACTED:FAKE_AGENT_TOKEN]"
}

@test "redact_secrets: leaves short env-var values alone to avoid mangling text" {
    _source_common
    export FAKE_AGENT_PASSWORD="ab"
    run redact_secrets <<< "absolutely normal text"
    assert_output "absolutely normal text"
}

@test "redact_secrets: passes clean text through unchanged" {
    _source_common
    run redact_secrets <<< "a perfectly ordinary envelope"
    assert_output "a perfectly ordinary envelope"
}

@test "REGRESSION v1.2.0: run_claude redacts the envelope and the stderr log at capture" {
    _source_common
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
echo "denied command echoed: curl -H ghp_abcdefghijklmnopqrstuvwxyz1234" >&2
echo '{"result":"phase output containing ghp_abcdefghijklmnopqrstuvwxyz1234"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    run run_claude "test prompt"
    refute_output --partial "ghp_abcdefghijklmnopqrstuvwxyz1234"
    assert_output --partial "[REDACTED_TOKEN]"

    ! grep -q "ghp_abcdefghijklmnopqrstuvwxyz1234" "${AGENT_LOG_DIR}"/claude-stderr-*.log
    grep -q "REDACTED_TOKEN" "${AGENT_LOG_DIR}"/claude-stderr-*.log
}

# ═══════════════════════════════════════════════════════════════
# classify_claude_result tests (#90)
# ═══════════════════════════════════════════════════════════════

@test "classify_claude_result: is_error true is fail_fast even with subtype success" {
    _source_common
    run classify_claude_result '{"is_error":true,"subtype":"success"}'
    assert_output "fail_fast"
}

@test "classify_claude_result: a turn cap is recoverable" {
    _source_common
    run classify_claude_result '{"is_error":false,"subtype":"error_max_turns"}'
    assert_output "recoverable"
}

@test "classify_claude_result: synthetic timeout envelope is recoverable" {
    _source_common
    run classify_claude_result '{"result":"Claude timed out or errored (exit code 124)","error":true}'
    assert_output "recoverable"
}

@test "classify_claude_result: success envelope is ok" {
    _source_common
    run classify_claude_result '{"is_error":false,"subtype":"success","result":"done"}'
    assert_output "ok"
}

@test "dispatch: implement handler classifies the envelope before the post-implementation gates" {
    grep -q "classify_claude_result" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

# ═══════════════════════════════════════════════════════════════
# preserve_branch — issue #73
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION issue-73: preserve_branch pushes the work branch" {
    _source_common
    git() { echo "git $*" >> "${TEST_TEMP_DIR}/git_calls"; return 0; }
    run preserve_branch
    assert_success
    run cat "${TEST_TEMP_DIR}/git_calls"
    assert_output --partial "push -u origin agent/issue-99"
}

@test "REGRESSION issue-73: preserve_branch push failure warns and returns 1" {
    _source_common
    git() { return 1; }
    run preserve_branch
    assert_failure
    assert_output --partial "WARN: could not push"
}

# ═══════════════════════════════════════════════════════════════
# PR body regression test
# ═══════════════════════════════════════════════════════════════

# ─── REGRESSION: v1.0.5 — Duplicate Summary heading ─────────────

@test "REGRESSION v1.0.5: PR body template does not contain ### Summary heading" {
    # The PR body in handle_post_implementation should NOT have ### Summary
    run grep '### Summary' "${LIB_DIR}/common.sh"
    assert_failure  # grep should NOT find it
}

# ═══════════════════════════════════════════════════════════════
# Test gate regression tests
# ═══════════════════════════════════════════════════════════════

# ─── REGRESSION: v1.0.3 — AGENT_TEST_SETUP_COMMAND ──────────────

# issue #73 moved the gate from handle_post_implementation into
# run_test_gate (review-gates.sh); the protected behavior travels with it.
@test "REGRESSION v1.0.3: test setup command present in the pre-PR test gate" {
    sed -n '/^run_test_gate()/,/^}/p' "${LIB_DIR}/review-gates.sh" | grep -q 'AGENT_TEST_SETUP_COMMAND'
}

@test "REGRESSION v1.0.3: test setup runs before test command in the gate source" {
    local body setup_line test_line
    body=$(sed -n '/^run_test_gate()/,/^}/p' "${LIB_DIR}/review-gates.sh")
    setup_line=$(echo "$body" | grep -n 'AGENT_TEST_SETUP_COMMAND' | head -1 | cut -d: -f1)
    test_line=$(echo "$body" | grep -n 'eval "\$AGENT_TEST_COMMAND"' | head -1 | cut -d: -f1)
    [ -n "$setup_line" ] && [ -n "$test_line" ]
    [ "$setup_line" -lt "$test_line" ]
}

# ─── REGRESSION: ERR trap double-report on controlled failures ──
# handle_post_implementation returns non-zero on controlled failures
# (test gate fail, Gate B halt, no commits made). Under `set -e` the
# unguarded call at the end of handle_implement would propagate that
# return to _on_unexpected_error via the ERR trap, which would
# double-post an "Agent Infrastructure Error" comment after the
# clean failure comment handle_post_implementation already posted.
# Observed on Webber #59 run 24280942202.
@test "REGRESSION: handle_post_implementation call in handle_implement is guarded" {
    # The call at the end of handle_implement must be wrapped in
    # `if ! handle_post_implementation ...; then ...; fi` (or equivalent
    # set-e suppression) so controlled return 1 values don't fire the
    # ERR trap.
    grep -q 'if ! handle_post_implementation' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "REGRESSION: cleanup_worktree runs after guarded handle_post_implementation" {
    # Even on controlled failure, cleanup must still happen so the
    # worktree doesn't leak on the runner. The guard should use an
    # if/fi block that falls through to cleanup_worktree, not a bare
    # `|| return` that would skip cleanup.
    local guard_line cleanup_line
    guard_line=$(grep -n 'if ! handle_post_implementation' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -1 | cut -d: -f1)
    cleanup_line=$(awk "NR > ${guard_line} && /cleanup_worktree/ {print NR; exit}" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
    [ -n "$cleanup_line" ]
    [ "$cleanup_line" -gt "$guard_line" ]
}

# ═══════════════════════════════════════════════════════════════
# log function tests
# ═══════════════════════════════════════════════════════════════

@test "log: writes timestamped message to log file" {
    _source_common
    log "Test message"

    assert [ -f "$AGENT_LOG_DIR/sandbox-pal-dispatch.log" ]
    grep -q "Test message" "$AGENT_LOG_DIR/sandbox-pal-dispatch.log"
}

@test "log: includes event type and issue number" {
    _source_common
    log "Test message"

    grep -q "\[test\] #99" "$AGENT_LOG_DIR/sandbox-pal-dispatch.log"
}

# ═══════════════════════════════════════════════════════════════
# Label management tests
# ═══════════════════════════════════════════════════════════════

@test "set_label: calls gh to add label" {
    create_mock "gh" ""
    _source_common

    set_label "agent:triage"

    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"add-label"* ]]
    [[ "$calls" == *"agent:triage"* ]]
}

# ═══════════════════════════════════════════════════════════════
# Circuit breaker tests
# ═══════════════════════════════════════════════════════════════

@test "check_circuit_breaker: passes when below limit" {
    create_mock "gh" "3"
    _source_common

    run check_circuit_breaker
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# Shared memory tests
# ═══════════════════════════════════════════════════════════════

@test "load_shared_memory: returns empty when no memory file" {
    export AGENT_MEMORY_FILE=""
    _source_common

    run load_shared_memory
    assert_output ""
}

@test "load_shared_memory: loads memory file content" {
    local mem_file="${TEST_TEMP_DIR}/memory.md"
    echo "# Project Memory" > "$mem_file"
    export AGENT_MEMORY_FILE="$mem_file"
    _source_common

    run load_shared_memory
    assert_output --partial "Project Memory"
    assert_output --partial "Shared Project Memory"
}

@test "load_shared_memory: resolves workspace-relative path against WORKTREE_DIR" {
    local worktree="${TEST_TEMP_DIR}/worktree"
    mkdir -p "$worktree/claude-work"
    echo "# Committed Memory" > "$worktree/claude-work/shared-memory.md"
    export AGENT_MEMORY_FILE="claude-work/shared-memory.md"
    export WORKTREE_DIR="$worktree"
    _source_common

    run load_shared_memory
    assert_output --partial "Committed Memory"
    assert_output --partial "Shared Project Memory"
}

@test "load_shared_memory: relative path not in worktree returns empty" {
    export AGENT_MEMORY_FILE="claude-work/nonexistent.md"
    export WORKTREE_DIR="${TEST_TEMP_DIR}/empty-worktree"
    mkdir -p "$WORKTREE_DIR"
    _source_common

    run load_shared_memory
    assert_output ""
}

# ═══════════════════════════════════════════════════════════════
# validate prompt tests
# ═══════════════════════════════════════════════════════════════

@test "load_prompt: loads default validate prompt" {
    _source_common
    run load_prompt "validate" ""
    assert_success
    assert_output --partial "validating"
}

@test "load_prompt: loads custom validate prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/custom-validate.md"
    echo "Custom validate prompt" > "$prompt_file"

    run load_prompt "validate" "$prompt_file"
    assert_success
    assert_output "Custom validate prompt"
}

# ═══════════════════════════════════════════════════════════════
# run_claude model configuration tests
# ═══════════════════════════════════════════════════════════════

@test "run_claude: passes --model flag when AGENT_MODEL is set" {
    create_mock "claude" '{"result":"ok"}'
    create_mock "timeout" '{"result":"ok"}'
    export AGENT_MODEL="claude-opus-4-6"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    # Create a wrapper that captures claude args
    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
# Skip the timeout arg, capture the rest
shift  # timeout value
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"--model"* ]]
    [[ "$calls" == *"claude-opus-4-6"* ]]
}

@test "run_claude: omits --model flag when AGENT_MODEL is empty" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL=""
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" != *"--model"* ]]
}

@test "run_claude: per-workflow override passes as --model" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL=""
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" "claude-haiku-4-5"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"--model"* ]]
    [[ "$calls" == *"claude-haiku-4-5"* ]]
}

@test "run_claude: per-workflow override wins over AGENT_MODEL" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL="claude-opus-4-6"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" "claude-haiku-4-5"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"claude-haiku-4-5"* ]]
    [[ "$calls" != *"claude-opus-4-6"* ]]
}

@test "run_claude: falls back to AGENT_MODEL when override arg is empty" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL="claude-opus-4-6"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" ""
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"--model"* ]]
    [[ "$calls" == *"claude-opus-4-6"* ]]
}

# Guards against accidental regression to a pinned default. With no model vars
# set, --model must not appear so the CLI picks its current latest model.
@test "run_claude: default-default omits --model entirely (lets CLI pick latest)" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL=""
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" ""
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" != *"--model"* ]]
}

@test "defaults.sh: AGENT_MODEL and all per-workflow overrides default to empty (CLI picks latest)" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL AGENT_MODEL_TRIAGE AGENT_MODEL_IMPLEMENT AGENT_MODEL_REVIEW \
          AGENT_MODEL_ADVERSARIAL_PLAN AGENT_MODEL_POST_IMPL_REVIEW AGENT_MODEL_POST_IMPL_RETRY

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_MODEL" ""
    assert_equal "$AGENT_MODEL_TRIAGE" ""
    assert_equal "$AGENT_MODEL_IMPLEMENT" ""
    assert_equal "$AGENT_MODEL_REVIEW" ""
    assert_equal "$AGENT_MODEL_ADVERSARIAL_PLAN" ""
    assert_equal "$AGENT_MODEL_POST_IMPL_REVIEW" ""
    assert_equal "$AGENT_MODEL_POST_IMPL_RETRY" ""
}

# ═══════════════════════════════════════════════════════════════
# Adversarial review prompt tests
# ═══════════════════════════════════════════════════════════════

@test "load_prompt: loads default adversarial-plan prompt" {
    _source_common
    run load_prompt "adversarial-plan" ""
    assert_success
    assert_output --partial "adversarial"
}

@test "load_prompt: loads custom adversarial-plan prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/custom-adversarial.md"
    echo "Custom adversarial prompt" > "$prompt_file"

    run load_prompt "adversarial-plan" "$prompt_file"
    assert_success
    assert_output "Custom adversarial prompt"
}

@test "load_prompt: loads default post-impl-review prompt" {
    _source_common
    run load_prompt "post-impl-review" ""
    assert_success
    assert_output --partial "post-implementation"
}

@test "load_prompt: loads custom post-impl-review prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/custom-post-impl.md"
    echo "Custom post-impl review prompt" > "$prompt_file"

    run load_prompt "post-impl-review" "$prompt_file"
    assert_success
    assert_output "Custom post-impl review prompt"
}

@test "load_prompt: loads default post-impl-retry prompt" {
    _source_common
    run load_prompt "post-impl-retry" ""
    assert_success
    assert_output --partial "review concerns"
}

@test "load_prompt: test-fix falls back to built-in prompt" {
    _source_common
    run load_prompt "test-fix" ""
    assert_success
    assert_output --partial "pre-PR test gate failed"
}

# ═══════════════════════════════════════════════════════════════
# handle_post_implementation × review loop
# ═══════════════════════════════════════════════════════════════

_setup_post_impl() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    export REPO_DIR="${TEST_TEMP_DIR}/repo"
    export BRANCH_NAME="agent/issue-99"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    # Establish a resolvable origin/main (a real worktree always has one) so
    # the empty-start_sha commit_count fallback in handle_post_implementation
    # (git rev-list --count origin/main..HEAD) counts the commit below instead
    # of erroring out to 0 and mis-taking the "no commits" branch.
    (cd "$WORKTREE_DIR" && echo base > base.txt && git add base.txt && git commit -qm "base")
    git -C "$WORKTREE_DIR" update-ref refs/remotes/origin/main HEAD
    (cd "$WORKTREE_DIR" && echo x > f.txt && git add f.txt && git commit -qm "impl commit")
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/review-gates.sh"
    source "${LIB_DIR}/notify.sh"
    export AGENT_TEST_COMMAND=""
    # git push / gh must not hit the network
    create_mock "gh" "https://github.com/test-org/test-repo/pull/123"
    git() { if [ "$1" = "-C" ] && [ "$3" = "push" ]; then return 0; fi; command git "$@"; }
}

@test "post-impl: clean loop creates PR with ledger summary in body" {
    _setup_post_impl
    run_post_impl_review_loop() { _ledger_init; _ledger_merge_review '{"findings":[]}'; return 0; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_success
    # gh mock records args; PR body must include the ledger summary header
    run cat "${TEST_TEMP_DIR}/mock_calls_gh"
    assert_output --partial "Review cycles:"
}

@test "post-impl: cap-hit still creates PR and applies agent:review-unresolved" {
    _setup_post_impl
    run_post_impl_review_loop() {
        _ledger_init
        _ledger_merge_review '{"findings":[{"severity":"blocking","description":"unresolved gap"}]}'
        return 2
    }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_success
    run cat "${TEST_TEMP_DIR}/mock_calls_gh"
    assert_output --partial "agent:review-unresolved"
    assert_output --partial "unresolved gap"
}

@test "post-impl: loop hard failure halts PR creation" {
    _setup_post_impl
    run_post_impl_review_loop() { return 1; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_failure
}

@test "labels: agent:review-unresolved is a known agent label" {
    source "${LIB_DIR}/common.sh"
    [[ " ${ALL_AGENT_LABELS[*]} " == *" agent:review-unresolved "* ]]
}

# ═══════════════════════════════════════════════════════════════
# extract_plan_branch
# ═══════════════════════════════════════════════════════════════

@test "extract_plan_branch: finds marker branch" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-plan -->
<!-- agent-branch: feature/400-async-rest-settle -->
# Plan body"
    assert_output "feature/400-async-rest-settle"
}

@test "extract_plan_branch: empty when no marker" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-plan -->
# Plan body"
    assert_output ""
}

@test "extract_plan_branch: rejects unsafe characters" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: feature/400;rm -rf / -->"
    assert_output ""
}

@test "extract_plan_branch: uses first marker only" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: feature/1-a -->
<!-- agent-branch: feature/2-b -->"
    assert_output "feature/1-a"
}

# ─── Finding 2: dangerous branch names must be rejected ─────────

@test "extract_plan_branch: rejects exact 'main'" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: main -->"
    assert_output ""
}

@test "extract_plan_branch: rejects exact 'master'" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: master -->"
    assert_output ""
}

@test "extract_plan_branch: rejects leading-dash first segment" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: -x/evil -->"
    assert_output ""
}

@test "extract_plan_branch: rejects leading-dash later segment" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: feature/--force -->"
    assert_output ""
}

@test "extract_plan_branch: rejects un-namespaced branch name" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: mybranch -->"
    assert_output ""
}

@test "extract_plan_branch: still accepts namespaced feature branch" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: feature/400-async-rest-settle -->"
    assert_output "feature/400-async-rest-settle"
}

@test "extract_plan_branch: still accepts a fix/ namespaced branch" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: fix/123-some-bug -->"
    assert_output "fix/123-some-bug"
}

@test "REGRESSION issue-73: work branch is preserved before the test gate runs" {
    _setup_post_impl
    preserve_branch() { echo "preserve" >> "${TEST_TEMP_DIR}/order"; return 0; }
    run_test_gate() { echo "gate" >> "${TEST_TEMP_DIR}/order"; return 0; }
    run_post_impl_review_loop() { _ledger_init; _ledger_merge_review '{"findings":[]}'; return 0; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_success
    run cat "${TEST_TEMP_DIR}/order"
    assert_line --index 0 "preserve"
    assert_line --index 1 "gate"
}

@test "REGRESSION issue-73: test gate failure halts before PR creation" {
    _setup_post_impl
    preserve_branch() { :; }
    run_test_gate() { return 1; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_failure
    run get_mock_calls "gh"
    refute_output --partial "pr create"
}

# ═══════════════════════════════════════════════════════════════
# REGRESSION: v1.2.0 — terminal agent:done label (#74)
# Closed issues kept stale agent:* state labels after PR merge.
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION v1.2.0: ALL_AGENT_LABELS includes agent:done" {
    _source_common
    local found=false
    for label in "${ALL_AGENT_LABELS[@]}"; do
        [ "$label" = "agent:done" ] && found=true
    done
    [ "$found" = "true" ]
}

@test "labels.txt: defines agent:done" {
    run grep -E '^agent:done\|' "${SCRIPTS_DIR}/../labels.txt"
    assert_success
}

@test "mark_issue_done: best-effort creates the label, then sets agent:done on the given issue" {
    _source_common
    gh() { echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"; }
    mark_issue_done "55"
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "label create agent:done"
    assert_output --partial "issue edit 55 --repo test-org/test-repo --add-label agent:done"
}

@test "mark_issue_done: strips prior state labels before adding agent:done" {
    _source_common
    gh() { echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"; }
    mark_issue_done "55"
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 55 --repo test-org/test-repo --remove-label agent:pr-open"
}

@test "mark_issue_done: leaves the caller's NUMBER untouched" {
    _source_common
    gh() { :; }
    NUMBER="99"
    mark_issue_done "55"
    assert_equal "$NUMBER" "99"
}
