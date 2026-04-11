#!/bin/bash
# ─── Common test helpers for BATS tests ──────────────────────────

# Resolve test root directory
TEST_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

# Load bats libraries
load "${TEST_ROOT}/test_helper/bats-support/load"
load "${TEST_ROOT}/test_helper/bats-assert/load"

# Path to the scripts under test
SCRIPTS_DIR="$(cd "${TEST_ROOT}/../scripts" && pwd)"
LIB_DIR="${SCRIPTS_DIR}/lib"
PROMPTS_DIR="$(cd "${TEST_ROOT}/../prompts" && pwd)"

# Create a temporary directory for each test
setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    export TEST_TEMP_DIR

    # Mock config directory
    MOCK_CONFIG_DIR="${TEST_TEMP_DIR}/config"
    mkdir -p "$MOCK_CONFIG_DIR"

    # Mock log directory
    export AGENT_LOG_DIR="${TEST_TEMP_DIR}/logs"
    mkdir -p "$AGENT_LOG_DIR"

    # Set required variables that lib scripts expect
    export EVENT_TYPE="test"
    export NUMBER="99"
    export REPO="test-org/test-repo"
    export REPO_NAME="test-repo"
    export TIMESTAMP="20260321-120000"
    export AGENT_BOT_USER="test-bot"
    export AGENT_MAX_TURNS=10
    export AGENT_TIMEOUT=60
    export AGENT_CIRCUIT_BREAKER_LIMIT=8
    export AGENT_MEMORY_FILE=""
    export AGENT_TEST_COMMAND=""
    export AGENT_TEST_SETUP_COMMAND=""
    export AGENT_EFFORT_LEVEL="high"
    export AGENT_ALLOWED_TOOLS_TRIAGE="Read,Write,Grep,Glob,Bash(echo:*),Bash(cat:*),Bash(ls:*),Bash(find:*)"
    export AGENT_ALLOWED_TOOLS_IMPLEMENT="Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*)"
    export AGENT_EXTRA_TOOLS=""
    export AGENT_DISALLOWED_TOOLS="mcp__github__*"
    export AGENT_NOTIFY_DISCORD_WEBHOOK=""
    export AGENT_NOTIFY_DISCORD_THREAD_ID=""
    export AGENT_NOTIFY_LEVEL="actionable"
    export AGENT_PROMPT_TRIAGE=""
    export AGENT_PROMPT_IMPLEMENT=""
    export AGENT_PROMPT_REPLY=""
    export AGENT_PROMPT_REVIEW=""
    export AGENT_PROMPT_VALIDATE=""
    export AGENT_ALLOW_DIRECT_IMPLEMENT="true"
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_POST_IMPL_REVIEW="true"
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES="1"
    export AGENT_PROMPT_ADVERSARIAL_PLAN=""
    export AGENT_PROMPT_POST_IMPL_REVIEW=""
    export AGENT_PROMPT_POST_IMPL_RETRY=""
    export AGENT_MODEL=""
    export SCRIPT_DIR="$SCRIPTS_DIR"
    export CONFIG_DIR=""
    export WORKTREE_DIR="${TEST_TEMP_DIR}/worktree"
    export BRANCH_NAME="agent/issue-99"

    mkdir -p "$WORKTREE_DIR"
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

# ─── Mock functions ──────────────────────────────────────────────

# Create a mock executable that records its calls and returns specified output
# Usage: create_mock "gh" "mock output"
create_mock() {
    local name="$1"
    local output="${2:-}"
    local exit_code="${3:-0}"
    local mock_bin="${TEST_TEMP_DIR}/bin"
    mkdir -p "$mock_bin"

    cat > "${mock_bin}/${name}" << MOCK
#!/bin/bash
echo "\$@" >> "${TEST_TEMP_DIR}/mock_calls_${name}"
echo "${output}"
exit ${exit_code}
MOCK
    chmod +x "${mock_bin}/${name}"
    export PATH="${mock_bin}:${PATH}"
}

# Get recorded calls to a mock
# Usage: get_mock_calls "gh"
get_mock_calls() {
    local name="$1"
    cat "${TEST_TEMP_DIR}/mock_calls_${name}" 2>/dev/null || echo ""
}
