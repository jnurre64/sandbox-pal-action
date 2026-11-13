#!/bin/bash
# ─── Sandbox profiles for phases (#137) ──────────────────────────
# Provides: agent_sandbox_profile, agent_sandbox_check,
#           agent_sandbox_config, agent_sandbox_write_excludes,
#           agent_sandbox_git_env, agent_sandbox_run, agent_sandbox_smoke,
#           agent_sandbox_tool_list,
#           agent_phase_token_check, agent_phase_token_export
#
# Permission rules decide what a phase is asked to do; they do not
# contain it. The `strict` profile does: the whole phase process runs
# under the sandbox runtime (`srt`, from @anthropic-ai/sandbox-runtime),
# which uses bubblewrap to give it a filesystem where only the worktree
# is writable and credential paths are absent, and a network that
# reaches only the listed hosts. It covers the model's own file tools,
# hooks and MCP servers, not only shell commands.
#
# Off unless a repo asks for it: AGENT_SANDBOX=strict, or per phase
# AGENT_SANDBOX_<PHASE>.

# Hosts every sandboxed phase may reach: the model provider, and GitHub
# for reads with the phase's own read-only token.
AGENT_SANDBOX_DEFAULT_DOMAINS=(
    api.anthropic.com "*.anthropic.com"
    claude.ai "*.claude.ai" claude.com "*.claude.com"
    github.com api.github.com codeload.github.com
    raw.githubusercontent.com objects.githubusercontent.com
)

# Credential stores hidden from every sandboxed phase, relative to $HOME.
AGENT_SANDBOX_CREDENTIAL_PATHS=(
    .ssh .gnupg .aws .azure .kube .docker .netrc .git-credentials
    .npmrc .pypirc .config/gh .config/gcloud .config/git/credentials
)

# Under the Claude config directory a phase may write (sessions, memory,
# a refreshed login), but not the files that decide what a later,
# unsandboxed session runs.
AGENT_SANDBOX_CLAUDE_PROTECTED=(
    settings.json settings.local.json CLAUDE.md
    skills plugins commands agents hooks
)

# Names the runtime mounts over inside the working directory to protect
# them. Where the file does not exist, the mount shows up as an untracked
# path and `git add -A` aborts on it, so the phase's git ignores them.
AGENT_SANDBOX_PHANTOM_PATHS=(
    .bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .gitmodules
    .ripgreprc .mcp.json .vscode .idea .claude/commands .claude/agents
)

# Print the profile for phase $1: none or strict.
agent_sandbox_profile() {
    local phase="${1:-}" var profile
    var="AGENT_SANDBOX_${phase}"
    profile="${AGENT_SANDBOX:-none}"
    if [ -n "$phase" ] && [ -n "${!var:-}" ]; then
        profile="${!var}"
    fi
    case "$profile" in
        none|strict) printf '%s\n' "$profile" ;;
        gpu) echo "${phase:-phase}: the gpu sandbox profile is not available in this release (use none or strict)" >&2; return 1 ;;
        *) echo "${phase:-phase}: AGENT_SANDBOX must be none or strict" >&2; return 1 ;;
    esac
}

# The runtime's command: AGENT_SANDBOX_SRT, or `srt` on PATH.
_sandbox_srt() {
    printf '%s\n' "${AGENT_SANDBOX_SRT:-srt}"
}

# Check what `strict` needs is installed. Prints what is missing.
agent_sandbox_check() {
    local tool missing=""
    for tool in "$(_sandbox_srt)" bwrap socat rg; do
        command -v "$tool" >/dev/null 2>&1 || missing+="${missing:+, }${tool##*/}"
    done
    if [ -n "$missing" ]; then
        echo "the strict sandbox profile needs: ${missing} (see docs/sandbox.md)" >&2
        return 1
    fi
}

# Split a space- or comma-separated setting into a JSON array.
_sandbox_list() {
    local item
    for item in ${1//,/ }; do
        printf '%s\n' "$item"
    done | jq -Rn '[inputs | select(length > 0)]'
}

# Print the existing paths among the arguments, as a JSON array.
_sandbox_existing() {
    local path
    for path in "$@"; do
        [ -e "$path" ] && printf '%s\n' "$path"
    done | jq -Rn '[inputs]'
}

# Print the runtime configuration for a phase working in $WORKTREE_DIR.
agent_sandbox_config() {
    local worktree git_dir claude_dir path
    worktree=$(cd "$WORKTREE_DIR" && pwd -P) || return 1
    git_dir=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || git_dir=""
    [[ "$git_dir" = /* ]] && [ -d "$git_dir" ] || git_dir=""
    claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

    local -a deny_read=() allow_write=("$worktree" /tmp "$claude_dir") deny_write=()
    for path in "${AGENT_SANDBOX_CREDENTIAL_PATHS[@]}"; do
        deny_read+=("${HOME}/${path}")
    done
    # The install's own secrets, and the token a phase is handed as GH_TOKEN.
    [ -z "${SCRIPT_DIR:-}" ] || deny_read+=("${SCRIPT_DIR}/../config.env")
    [ -z "${AGENT_CONFIG:-}" ] || deny_read+=("$AGENT_CONFIG")
    [ -z "${AGENT_PHASE_GH_TOKEN_FILE:-}" ] || deny_read+=("$(_phase_token_path)")
    if [ -n "$git_dir" ]; then
        # A worktree's git data lives in the clone's .git. Its hooks and
        # config would run or apply outside the sandbox later.
        allow_write+=("$git_dir")
        deny_write+=("${git_dir}/hooks" "${git_dir}/config")
    fi
    for path in "${AGENT_SANDBOX_CLAUDE_PROTECTED[@]}"; do
        deny_write+=("${claude_dir}/${path}")
    done
    # Dispatch logs, locks and this run's generated files.
    [ -z "${AGENT_LOG_DIR:-}" ] || deny_write+=("$AGENT_LOG_DIR")

    jq -n \
        --argjson domains "$(printf '%s\n' "${AGENT_SANDBOX_DEFAULT_DOMAINS[@]}" | jq -Rn '[inputs]')" \
        --argjson extra_domains "$(_sandbox_list "${AGENT_SANDBOX_ALLOWED_DOMAINS:-}")" \
        --argjson deny_read "$(_sandbox_existing "${deny_read[@]}")" \
        --argjson extra_deny_read "$(_sandbox_list "${AGENT_SANDBOX_DENY_READ:-}")" \
        --argjson allow_write "$(printf '%s\n' "${allow_write[@]}" | jq -Rn '[inputs]')" \
        --argjson extra_allow_write "$(_sandbox_list "${AGENT_SANDBOX_ALLOW_WRITE:-}")" \
        --argjson deny_write "$(printf '%s\n' "${deny_write[@]}" | jq -Rn '[inputs]')" \
        --argjson unix_sockets "$([ "${AGENT_SANDBOX_UNIX_SOCKETS:-false}" = true ] && echo true || echo false)" \
        '{
            network: ({allowedDomains: ($domains + $extra_domains | unique), deniedDomains: []}
                + (if $unix_sockets then {allowAllUnixSockets: true} else {} end)),
            filesystem: {
                denyRead: ($deny_read + $extra_deny_read + ["**/.env"] | unique),
                allowWrite: ($allow_write + $extra_allow_write | unique),
                denyWrite: ($deny_write | unique)
            }
        }'
}

# Write the git excludes file for a sandboxed phase to $1: the phantom
# paths, after whatever the operator's own global excludes file holds.
agent_sandbox_write_excludes() {
    local file="$1" own
    own=$(git config --global --get core.excludesFile 2>/dev/null || true)
    own="${own/#\~/$HOME}"
    [ -n "$own" ] || own="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
    {
        [ ! -f "$own" ] || cat "$own"
        printf '%s\n' "${AGENT_SANDBOX_PHANTOM_PATHS[@]}"
    } > "$file"
}

# Point the phase's git at excludes file $1, through the environment, so
# nothing is left behind in the clone's configuration.
agent_sandbox_git_env() {
    local index="${GIT_CONFIG_COUNT:-0}"
    [[ "$index" =~ ^[0-9]+$ ]] || index=0
    export "GIT_CONFIG_KEY_${index}=core.excludesFile" "GIT_CONFIG_VALUE_${index}=$1"
    export GIT_CONFIG_COUNT=$((index + 1))
}

# Run a command under runtime configuration file $1.
agent_sandbox_run() {
    local config="$1"
    shift
    "$(_sandbox_srt)" -s "$config" -- "$@"
}

# ─── Tool lists under a sandbox (#143) ───────────────────────────
# Outside a sandbox the Bash prefix rules are the only limit on shell
# commands, so the lists grow long and still refuse ordinary shell
# (variables, redirects, loops). Inside one the sandbox is the limit, so
# every Bash(...) rule in list $1 collapses into a single `Bash` rule.
# Rules for other tools are kept as written, and a list with no Bash
# rule at all is not given shell access.
agent_sandbox_tool_list() {
    local rule out="" has_bash=false
    while IFS= read -r rule; do
        case "$rule" in
            Bash|"Bash("*)
                [ "$has_bash" = true ] && continue
                has_bash=true
                rule=Bash ;;
        esac
        out+="${out:+,}${rule}"
    done < <(agent_split_tool_rules "$1")
    printf '%s\n' "$out"
}

# Start the sandbox once with the phase's configuration and run nothing in
# it. Prints the runtime's complaint when it cannot start (a missing
# dependency, or a kernel that forbids unprivileged user namespaces).
agent_sandbox_smoke() {
    local config output rc=0
    agent_sandbox_check || return 1
    config=$(mktemp "${AGENT_LOG_DIR}/sandbox-check-XXXXXX.json") || return 1
    agent_sandbox_config > "$config" || { rm -f "$config"; return 1; }
    output=$(cd "$WORKTREE_DIR" && agent_sandbox_run "$config" true 2>&1) || rc=$?
    rm -f "$config"
    [ "$rc" -eq 0 ] || { printf '%s\n' "${output:-the sandbox runtime exited with ${rc}}" >&2; return 1; }
}

# ─── The phase's own GitHub token ────────────────────────────────
# A sandboxed phase cannot see a stored GitHub login, and no phase gets
# the dispatcher's token (#142). AGENT_PHASE_GH_TOKEN_FILE names a file
# holding a token for phases, meant to be read-only: the dispatcher keeps
# every write. Only the path is configuration; the value is read at
# launch and never logged.

_phase_token_path() {
    local path="${AGENT_PHASE_GH_TOKEN_FILE:-}"
    path="${path/#\~/$HOME}"
    if [[ "$path" != /* ]] && [ -n "${CONFIG_DIR:-}" ]; then
        path="${CONFIG_DIR}/${path}"
    fi
    printf '%s\n' "$path"
}

agent_phase_token_check() {
    [ -n "${AGENT_PHASE_GH_TOKEN_FILE:-}" ] || return 0
    local path
    path=$(_phase_token_path)
    if [ ! -r "$path" ] || [ ! -s "$path" ]; then
        echo 'AGENT_PHASE_GH_TOKEN_FILE must name a readable, non-empty file' >&2
        return 1
    fi
}

# Export the token to the current shell as GH_TOKEN. Call it only in the
# engine's subshell, after agent_scrub_phase_env.
agent_phase_token_export() {
    [ -n "${AGENT_PHASE_GH_TOKEN_FILE:-}" ] || return 0
    agent_phase_token_check || return 1
    local token
    token=$(tr -d '[:space:]' < "$(_phase_token_path)") || return 1
    [ -n "$token" ] || { echo 'AGENT_PHASE_GH_TOKEN_FILE holds no token' >&2; return 1; }
    export GH_TOKEN="$token"
}
