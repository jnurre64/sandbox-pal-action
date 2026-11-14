# Configuration Reference

This document covers every configuration option in sandbox-pal-action, how values are loaded, and example configurations for different project types.

## Worker engine and model selection

Claude remains the default worker engine. Set `AGENT_ENGINE=codex` to select Codex,
or use `AGENT_ENGINE_<PHASE>` for mixed-engine dispatches. Each selected engine
uses its own CLI and standard authentication; preflight validates only reachable
engines. There is no automatic fallback. Interactive client choice does not select
worker engines, and existing Claude-only configurations keep their behavior.

Supported phase names are `TRIAGE`, `REPLY`, `VALIDATE`, `IMPLEMENT`, `REVIEW`
(PR feedback revisions), `ADVERSARIAL_PLAN`, `POST_IMPL_REVIEW`,
`POST_IMPL_RETRY`, `TEST_FIX`, and `CLEANUP`.

With `AGENT_ENGINE_PROFILES=false` (the default), model precedence is:

1. `AGENT_MODEL_<PHASE>`.
2. `AGENT_MODEL_CLAUDE` or `AGENT_MODEL_CODEX`, according to the phase engine.
3. Legacy `AGENT_MODEL`, only when the phase uses the dispatch default engine.
4. The selected CLI's default model.

For compatibility, `REPLY` and `VALIDATE` inherit `AGENT_MODEL_TRIAGE` before
step 2 when their own model is empty and their engine matches `TRIAGE`.
Recognizable cross-provider model mistakes fail configuration validation;
custom model IDs are passed unchanged, and availability still depends on the CLI
and provider.

Dispatch preflight runs after acquiring the existing issue lock and before
handlers reset worktrees or start workers. It checks reachable phases, including
reply branches, enabled independent reviews, and possible bounded fix sessions.
Disabled gates and unrelated events require no worker credentials. `status`
skips worker preflight entirely. Current checks cover validator/schema assets,
Claude CLI and `timeout` availability, local `claude auth status --json`, numeric
limits, and effort/permission values. They do not establish quota availability
or prove that every CLI version supports every optional flag.

On success, dispatch freezes resolved engine/model choices, schema contents, and
shell policy settings. File contents such as memory and MCP configuration are
not yet isolated or snapshotted by this mechanism. Preflight failure records
`agent:failed` through the existing lock/outcome machinery; process exit zero
still does not mean semantic success. Details are in the dispatch log and the
scrubbed `preflight-*.log` capture.

## Engine-specific configuration compatibility

Codex uses native policy by default. Legacy Claude tool lists, extra/label tools,
MCP configuration and turn caps apply to Claude workers. Selecting Codex does not
translate those strings into equivalent restrictions or alter the project's native
Codex integrations and research settings. Preflight logs the distinction.

`AGENT_CODEX_USE_NATIVE_POLICY` defaults to `true`. Set it to `false` only if you
want preflight to reject legacy Claude controls on Codex phases rather than scope
those settings to Claude. Normal engine selection requires no second opt-in.

In legacy mode, global or phase dollar budgets fail on reachable Codex phases because the adapter
cannot enforce a dollar cap. `AGENT_TIMEOUT` limits elapsed time. In hybrid
configurations, set budgets only on Claude phases. `AGENT_PERMISSION_MODE_<PHASE>`
also fails if assigned to a Codex phase; use supported native Codex configuration
instead. No Claude invocation flags or defaults are changed by this scoping.

For Claude implementation with a fresh Codex post-implementation review:

```bash
AGENT_ENGINE=claude
AGENT_ENGINE_POST_IMPL_REVIEW=codex
# Optionally set AGENT_MODEL_CODEX to your intended supported Codex model.
```

Codex advisory phases use read-only policy; editing phases use workspace-write.
Editing invocations explicitly include the checkout’s Git metadata directories
(including linked-worktree metadata and shared objects/refs) as native writable
paths so workers can create the commits required by the existing pipeline.
Native sandbox limits can still prevent worker-side test execution; the separate
dispatcher test gate remains authoritative.
Human plan approval, fresh reviews, test gates, recovery and semantic outcomes
remain shared. Workers are instructed to propose instruction-file improvements to
the orchestrator. Absolute prevention of every instruction edit or escaped child
process is deferred hardening, not an additional requirement over existing Claude
behavior. Neither engine is claimed to provide those stronger guarantees.

The Codex adapter closes object schemas and requires declared fields in the copy
sent to its strict structured-output API. Empty strings/arrays represent unused
fields where permitted. Shared schemas and Claude requests remain unchanged;
returned data is validated against the original phase contract. Custom schemas
with unsupported composition, arbitrary object keys or undeclared required fields
fail configuration validation. Real-provider and full pipeline acceptance are
still pending; actual-CLI loopback checks are not paid production acceptance.

## Retain both engines' settings

Set `AGENT_ENGINE_PROFILES=true` once to retain Claude and Codex settings in the
same configuration. It defaults to `false`; setup/update only deliver commented
entries and never adopt it for you. These profiles are groups of Bash project
settings, not Codex CLI permission profiles or separate credentials.

Before enabling, move any unqualified model/effort settings intended for Codex
into `AGENT_MODEL_CODEX[_<PHASE>]` / `AGENT_EFFORT_CODEX[_<PHASE>]`.
Legacy model, effort, budget, turns and permission settings then become Claude-only
fallbacks. Existing Claude tool, extra/label-tool and MCP settings stay Claude-only.
This deliberately stops applying shared dollar budgets to Codex: Codex has no
harness dollar or turn cap. `AGENT_CODEX_USE_NATIVE_POLICY=false` still rejects
conflicting legacy Claude tool/MCP/turn/budget/permission controls on Codex phases.
Native authentication, integrations and sandbox roles keep their existing behavior.

For example, in your existing project config (replace the model placeholders with
IDs supported by your provider):

```bash
AGENT_ENGINE_PROFILES="${AGENT_ENGINE_PROFILES:-true}"
AGENT_ENGINE="${AGENT_ENGINE:-claude}"
AGENT_MODEL_CLAUDE="${AGENT_MODEL_CLAUDE:-<Claude model ID>}"
AGENT_MODEL_CODEX="${AGENT_MODEL_CODEX:-<Codex model ID>}"
AGENT_MODEL_CLAUDE_IMPLEMENT="${AGENT_MODEL_CLAUDE_IMPLEMENT:-<Claude implementation model ID>}"
AGENT_MODEL_CODEX_IMPLEMENT="${AGENT_MODEL_CODEX_IMPLEMENT:-<Codex implementation model ID>}"
AGENT_BUDGET_USD_CLAUDE_IMPLEMENT="${AGENT_BUDGET_USD_CLAUDE_IMPLEMENT:-12}"
AGENT_MAX_TURNS_CLAUDE_IMPLEMENT="${AGENT_MAX_TURNS_CLAUDE_IMPLEMENT:-200}"
AGENT_PERMISSION_MODE_CLAUDE_IMPLEMENT="${AGENT_PERMISSION_MODE_CLAUDE_IMPLEMENT:-acceptEdits}"
AGENT_EFFORT_CLAUDE_IMPLEMENT="${AGENT_EFFORT_CLAUDE_IMPLEMENT:-max}"
AGENT_EFFORT_CODEX_IMPLEMENT="${AGENT_EFFORT_CODEX_IMPLEMENT:-high}"
AGENT_TIMEOUT_CLAUDE_IMPLEMENT="${AGENT_TIMEOUT_CLAUDE_IMPLEMENT:-3600}"
AGENT_TIMEOUT_CODEX_IMPLEMENT="${AGENT_TIMEOUT_CODEX_IMPLEMENT:-5400}"
```

After adoption, change only `AGENT_ENGINE` to switch the default from Claude to
Codex and back. For one-command all-phase switching and restoration, use
[named dispatch profiles](#named-dispatch-profiles). With raw routing, **to switch
all phases**, remove or clear every configured
`AGENT_ENGINE_<PHASE>` routing override, including incoming environment overrides.
To retain mixed phases instead, keep an explicit route such as
`AGENT_ENGINE_POST_IMPL_REVIEW=codex` with `AGENT_ENGINE=claude`, or reverse those
values for Codex implementation and a fresh Claude review. The review route
continues to win when you change the global default.

| Setting prefix | Engine namespaces | Default in profile mode |
| --- | --- | --- |
| `AGENT_MODEL` | `CLAUDE`, `CODEX` | CLI default |
| `AGENT_EFFORT` | `CLAUDE`, `CODEX` | Claude `high`; Codex native default |
| `AGENT_TIMEOUT` | `CLAUDE`, `CODEX` | Shared `AGENT_TIMEOUT`, then `3600` seconds |
| `AGENT_BUDGET_USD` | `CLAUDE` | No dollar cap |
| `AGENT_MAX_TURNS` | `CLAUDE` | `200` turns |
| `AGENT_PERMISSION_MODE` | `CLAUDE` | No explicit CLI flag |

Each prefix accepts both an engine default and an engine+phase override, e.g.
`AGENT_TIMEOUT_CODEX` and `AGENT_TIMEOUT_CODEX_TEST_FIX`. All ten phase names above
are supported, including retries, test fixes and cleanup. Only settings for the
selected reachable engine are validated; retaining inactive settings requires
neither that engine's CLI nor its authentication.

Resolution is engine+phase → engine default → Claude legacy fallback → defaults
in the table. Routing is phase engine → global engine → Claude. Claude legacy
model fallback uses the existing phase model (including same-engine
REPLY/VALIDATE-to-TRIAGE inheritance), then `AGENT_MODEL`. Legacy budget uses phase
then global budget; effort uses phase then `AGENT_EFFORT_LEVEL`; permission uses
the legacy phase value; turns use `AGENT_MAX_TURNS`. There is no new legacy
TRIAGE inheritance for effort, budget or permission. An explicit engine model
default outranks every legacy phase model. Model IDs are opaque in profile mode;
the selected provider checks their availability. Explicit model arguments to
direct `run_agent` / `run_claude` callers win before preflight; after preflight,
the frozen phase record wins. Internal phase calls leave this argument empty.

Empty supported optional values inherit. Nonempty `false`, `0`, whitespace and
malformed values do not disappear into defaults: limits must be positive, timeout
and turns must be integers, and budgets must be decimal dollar amounts. Claude
effort accepts `low`, `medium`, `high`, `xhigh`, `max`; Codex accepts `minimal`,
`low`, `medium`, `high`, `xhigh`. Claude permission modes retain `default`, `acceptEdits`, `auto`,
`bypassPermissions`, `manual`, `dontAsk`, and `plan`. Explicit unsupported Codex controls such as
`AGENT_BUDGET_USD_CODEX_IMPLEMENT`, `AGENT_MAX_TURNS_CODEX`, or
`AGENT_PERMISSION_MODE_CODEX_IMPLEMENT` fail even if assigned an empty string.
The same applies to Codex-namespaced allow/deny/extra/label-tool and MCP controls;
there is no translation into a Codex permission policy.

Preflight freezes each phase's model, effort, invocation timeout and applicable
limits. Its per-phase summary lists the selected model, timeout, limit types and
source key names; it identifies inactive Claude controls for Codex without
printing MCP contents, prompts or credentials. Direct callers use the same
resolver, and per-invocation Claude effort cannot leak into later phases.

A worker timeout bounds one invocation. The enclosing GitHub Actions
`timeout-minutes` or interactive session deadline is independent and can terminate
it sooner. There is no fixed 30-minute phase cap and no conversion of dollars or
turns into elapsed time. Shared prompts, schemas, tests, review gates, locks,
memory and recovery remain orchestration settings, without engine namespaces.

## Worker configuration in consuming workflows

Keep engine/model choices together in the existing project configuration file.
The distributed `config.defaults.env.example` lists engine and model overrides
for every supported phase; setup/update track these names for configuration
migration. The entries are commented, so installing them does not select Codex.

In standalone mode, place non-sensitive settings in
`.sandbox-pal-dispatch/config.defaults.env`, using the example's `${VAR:-default}`
assignment form to preserve environment overrides. Generated label and
`repository_dispatch` workflows execute the same local dispatcher and specify
`.sandbox-pal-dispatch/config.env` for optional overrides. Keep authentication
in that ignored override file or the runner's existing secret store.

In reference mode, set the reusable workflow's existing `config_path` input to
an absolute path on the runner. Every event for a project should use the same
configuration, including programmatic dispatch and retries. For example, under
the caller job's `with` mapping:

```yaml
bot_user: your-bot
dispatch_script: /home/runner/agent-infra/scripts/sandbox-pal-dispatch.sh
config_path: /home/runner/project-config/config.env
```

Set per-phase `AGENT_ENGINE_*` and `AGENT_MODEL_*` variables in that file using
the precedence described above. There is no new workflow permission format or
automatic engine switch. The shared preflight validates only reachable phases
for each event before any worker starts.
Workflow updates preserve consumer customizations: review changed templates and
apply relevant edits in `.github/workflows/`, retaining actor filters, concurrency
and human approval gates. Interactive client linking is described in the
[customization guide](customization.md#connect-a-reference-or-custom-runtime).

## Config Loading Order

The dispatcher sources these Bash files in order:

1. `config.defaults.env` beside the runtime's `scripts/` directory.
2. The existing file named by `AGENT_CONFIG`, or `config.env` beside `scripts/`.
3. `scripts/lib/defaults.sh`, which fills missing values.

Incoming environment values survive assignments such as
`AGENT_ENGINE="${AGENT_ENGINE:-claude}"`. An unconditional assignment such as
`AGENT_ENGINE=claude` in a sourced file overwrites the incoming value; environment
precedence is not automatic. Later unconditional assignments also replace earlier
file values. Use the environment-preserving form in shared project defaults,
and keep sensitive overrides in the existing ignored config or runner secrets.
Both interactive clients and label workflows use this same loading path when
invoking the same dispatcher/configuration.

When a sourced file overwrites an exported `AGENT_*` variable with a different
value, the dispatcher says so once at startup:

```
WARN: config overwrote exported environment: AGENT_BUDGET_USD_IMPLEMENT (config.defaults.env). The file's value is in use. …
```

The file's value stays in force; the warning only makes the lost override
visible. It lists names and the file that changed each one, never values. To let
the environment win for a variable, write its assignment in the
environment-preserving form. `AGENT_PROFILE` is not reported, because profile
selection reads the incoming value directly (see
[Selection precedence](#named-dispatch-profiles)).

---

## Required Settings

### AGENT_BOT_USER

The GitHub username of the bot account that will comment on issues, push branches, and create PRs.

```bash
AGENT_BOT_USER="my-bot-account"
```

This has no default. The dispatch script will exit with an error if it is not set. It is used to:
- Filter the circuit breaker (count only this user's comments)
- Identify bot-authored comments when extracting debug data
- Prevent the agent's own label changes from re-triggering workflows (via the actor filter in your calling workflow)

---

## Optional Settings

### AGENT_MAX_TURNS

Maximum number of Claude conversation turns per invocation. A higher value allows more complex tasks but increases cost and runtime.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MAX_TURNS` | `200` | integer |

```bash
AGENT_MAX_TURNS=200
```

### AGENT_TIMEOUT

Timeout in seconds before the dispatch script kills a stuck `claude -p` process. If Claude does not finish within this window, the process is terminated and the issue is marked as failed.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TIMEOUT` | `3600` | integer (seconds) |

```bash
AGENT_TIMEOUT=3600   # 1 hour
```

### AGENT_CIRCUIT_BREAKER_LIMIT

Maximum number of bot comments allowed per hour on a single issue. If the limit is exceeded, the agent halts with `agent:failed` and posts a warning. This prevents infinite loops.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_CIRCUIT_BREAKER_LIMIT` | `8` | integer |

```bash
AGENT_CIRCUIT_BREAKER_LIMIT=8
```

### AGENT_DISPATCH_PAUSED

A pause switch for the whole install. With any value other than `false`, every dispatch except `status` exits at once with outcome `paused` and exit code 0. It happens before the dispatch lock is taken: no label changes, nothing is posted, no worker starts. Set it in `config.env` to stop a machine's pipeline during maintenance, or in the environment for one command.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_DISPATCH_PAUSED` | `false` | `false`, or anything else to pause |

### Per-Phase Invocation Flags

Four independent controls on how each phase invokes the CLI. **Every one is optional and defaults to current behaviour.** Phase suffixes match the model-override vars: `TRIAGE`, `REPLY`, `IMPLEMENT`, `VALIDATE`, `REVIEW` (PR revision), `CLEANUP`, `ADVERSARIAL_PLAN`, `TEST_FIX`, `POST_IMPL_REVIEW`, `POST_IMPL_RETRY`.

| Key | Default | Effect |
|-----|---------|--------|
| `AGENT_BUDGET_USD_<PHASE>` | *(empty — limitless)* | `--max-budget-usd` for that phase |
| `AGENT_BUDGET_USD` | *(empty — limitless)* | fallback budget for phases without their own |
| `AGENT_EFFORT_<PHASE>` | *(empty)* | `--effort` for that phase (low/medium/high/xhigh) |
| `AGENT_PERMISSION_MODE_<PHASE>` | *(empty)* | `--permission-mode` for that phase |
| `AGENT_MCP_CONFIG` | *(empty)* | path → `--mcp-config <path> --strict-mcp-config`: phases get exactly these MCP servers |
| `AGENT_STRICT_MCP` | *(empty)* | `true` → `--strict-mcp-config` alone: phases get **no** MCP servers |
| `AGENT_SESSION_PERSISTENCE` | `false` | `true` keeps resumable phase sessions (default passes `--no-session-persistence`) |
| `AGENT_PERMISSION_PROMPTS` | `none` | `--permission-prompts` target for Claude phases: `none`, `host`, or empty to omit the flag |
| `AGENT_BG_WAIT_CEILING_MS_<PHASE>` | *(unset — uses the global)* | background-wait ceiling for that phase, in milliseconds |
| `AGENT_BG_WAIT_CEILING_MS` | `600000` | exported to Claude phases as `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`; empty leaves the CLI's own ceiling |
| `AGENT_SETTING_SOURCES` | `user,project,local` | `--setting-sources` for Claude phases: which settings layers are read besides the pipeline's own file. Empty omits the flag |
| `AGENT_SETTINGS_FILE` | *(empty)* | a settings JSON of your own that each phase's generated settings file is built on (absolute, or relative to the config directory) |
| `AGENT_CONTEXT_REFS_MAX` | `10` | how many issues and pull requests referenced by the issue text are pre-fetched into `.agent-data/context/references/`; `0` turns it off |
| `AGENT_SANDBOX` | `none` | sandbox profile for Claude phases: `none` or `strict` (the whole phase under the sandbox runtime). See [sandbox.md](sandbox.md) |
| `AGENT_SANDBOX_<PHASE>` | *(unset — uses the global)* | profile for that phase |
| `AGENT_SANDBOX_SRT` | *(empty — `srt` on `PATH`)* | path to the sandbox runtime |
| `AGENT_SANDBOX_ALLOWED_DOMAINS` | *(empty)* | further hosts a sandboxed phase may reach, space- or comma-separated |
| `AGENT_SANDBOX_DENY_READ` | *(empty)* | further paths hidden from a sandboxed phase |
| `AGENT_SANDBOX_ALLOW_WRITE` | *(empty)* | further paths a sandboxed phase may write |
| `AGENT_SANDBOX_SHORT_TOOLS` | `true` | under `strict`, replace a phase's `Bash(...)` prefix rules with one `Bash` rule; `false` keeps them as written |
| `AGENT_SANDBOX_UNIX_SOCKETS` | `false` | `true` lets a sandboxed phase use Unix sockets (needed by Xvfb) |
| `AGENT_PHASE_GH_TOKEN_FILE` | *(empty)* | file holding a GitHub token exported to every phase as `GH_TOKEN` (absolute, `~/…`, or relative to the config directory) |
| `AGENT_PHASE_SCRUB_ENV` | *(empty)* | space-separated names of further variables to remove from every phase's environment |
| `AGENT_PHASE_KEEP_ENV` | *(empty)* | space-separated names to leave in a phase's environment despite the built-in list |

Notes:
- **Phases are launched without the dispatcher's credentials** — `GH_TOKEN`, `GITHUB_TOKEN`, `AGENT_GIST_PAT`, the notification webhooks and bot tokens, for both worker engines. The dispatcher keeps them and does all GitHub work itself. A custom prompt that calls `gh` inside a phase will find no token: move that step into the dispatcher's flow, or name the variable in `AGENT_PHASE_KEEP_ENV` and accept that every phase can then read it. The full list and the limits are in [security.md](security.md#phase-environment).
- **Each Claude phase runs on a settings file the pipeline writes** and passes with `--settings`. It holds the phase's allowed tools as `permissions.allow` and `AGENT_DISALLOWED_TOOLS` as `permissions.deny`; the rules are no longer passed as `--allowedTools` and `--disallowedTools`. The file is created for one phase run and removed afterwards. `AGENT_SETTINGS_FILE` names a JSON file of your own to build it on, for anything else a phase should have (hooks, `env`, `enabledPlugins`, further rules); the phase's rules are appended to whatever that file already lists.
- **`AGENT_SETTING_SOURCES`** chooses the other settings layers a phase reads. The default, `user,project,local`, is what the CLI does when the flag is absent, so an existing install is unchanged. **`project` is the recommended value**: a phase then stops reading the operator's user settings, so its behaviour no longer depends on which rules, hooks and plugins one person's machine has collected. Checked against CLI 2.1.323 with `project`: plugins enabled in user settings and skills under the user's `~/.claude/skills` are not loaded; auto-memory, the project's `CLAUDE.md`, project skills and the login still are. If your phases rely on a user-level plugin or skill, enable it for them through `AGENT_SETTINGS_FILE` or the project's own `.claude/` before switching. Managed (policy) settings always apply.
- **Budget is deliberately limitless by default** — turns (`AGENT_MAX_TURNS`) and the timeout still bound every phase; a dollar cap is the operator's choice. Turns and dollars are not interchangeable bounds: a phase can be cheap and long or short and expensive. If you set caps, size generously for write phases — a revision that runs out mid-way (work committed, reply unfinished) is worse than one that never started.
- Without `AGENT_MCP_CONFIG`/`AGENT_STRICT_MCP`, a phase run on a machine with user-level MCP servers silently inherits them. This matters most in orchestrator mode, where inheritance is otherwise the point: *inherit identity, memory and skills; gate the tool surface explicitly.*
- A workable effort/permission spread from a reference implementation: `dontAsk` for read-only phases (triage, reviews, cleanup), `acceptEdits` for writers (implement, test-fix, retry, revision); effort `high` for triage/review, `xhigh` for implement/retry/revision.
- **`AGENT_PERMISSION_PROMPTS=none`** tells the CLI that nobody will answer a permission prompt, so a call that would prompt is denied at once and listed in the envelope's `permission_denials` (see "Permission Denials" in the PR body and failure comments). The permission mode and the allow list still decide everything else. The dispatcher passes the flag only when the installed CLI's `--help` lists `--permission-prompts`, so an older CLI keeps working without it.
- **`AGENT_BG_WAIT_CEILING_MS`** bounds how long `claude -p` waits for background work it started before returning its result. Without a bound below `AGENT_TIMEOUT`, a stuck background task holds the phase until the outer `timeout` kills the CLI, and the result envelope is lost with it. The default, ten minutes, is the CLI's own ceiling as of 2.1.322; setting it here keeps the bound the same across CLI versions. Raise it per phase (`AGENT_BG_WAIT_CEILING_MS_IMPLEMENT`) for a project whose phases legitimately wait longer on background work, and keep it under the phase timeout. Both settings apply to Claude phases only, and both are checked at preflight: an unknown prompt target or a non-numeric ceiling stops the dispatch before any phase runs.

### AGENT_JSON_SCHEMA_* (structured phase output)

Each machine-consumed phase passes a JSON Schema to `claude -p --json-schema`, so the CLI returns a guaranteed-shape object in the envelope's `structured_output` field instead of the dispatch script parsing free text. Handlers prefer the validated object and fall back to text extraction, so older CLIs and custom prompts keep working.

| Key | Default | Phase |
|-----|---------|-------|
| `AGENT_JSON_SCHEMA_TRIAGE` | `schemas/triage.json` | triage |
| `AGENT_JSON_SCHEMA_REPLY` | `schemas/reply.json` | issue reply |
| `AGENT_JSON_SCHEMA_VALIDATE` | `schemas/validate.json` | direct-implement validation |
| `AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN` | `schemas/adversarial-plan.json` | Gate A plan review |
| `AGENT_JSON_SCHEMA_POST_IMPL_REVIEW` | `schemas/post-impl-review.json` | Gate B review |
| `AGENT_JSON_SCHEMA_POST_IMPL_RETRY` | `schemas/post-impl-retry.json` | Gate B retry |
| `AGENT_JSON_SCHEMA_CLEANUP` | `schemas/cleanup.json` | post-merge cleanup |

Set a variable to `""` (explicitly empty) to disable that phase's schema, or point it at your own file — absolute, or relative to the config directory. Phases with no machine-consumed result (`implement`, `pr_review` revision) take no schema. If you override a phase's prompt with a different output contract, override or disable its schema to match — a configured schema whose shape the prompt never produces is reported as a schema/prompt mismatch, distinct from an agent failure.

### AGENT_EXECUTION_MODE

How the dispatch script is being invoked. `actions` (the default) is the GitHub Actions workflow path and changes nothing. `orchestrator` is for invocation by an interactive Claude Code session (see the Orchestrator Mode section of the architecture guide): human-readable log output moves to stderr, and the final line of stdout becomes a compact JSON result object for the calling session to parse. Usually set per-invocation by the `sp-*` skills (`AGENT_EXECUTION_MODE=orchestrator scripts/sandbox-pal-dispatch.sh …`) rather than in config.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_EXECUTION_MODE` | `actions` | `actions` \| `orchestrator` |

### AGENT_LOCK_DIR

Directory for per-issue dispatch locks and last-dispatch outcome records (see the Dispatch Liveness section of the architecture guide). The lock enforces one dispatch per issue and carries a phase heartbeat; the last-dispatch record preserves each run's outcome even when the caller lost track of it.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_LOCK_DIR` | `$AGENT_LOG_DIR/locks` | directory path |

### AGENT_ADD_DIRS

Space-separated list of extra directories phases may access without prompting, passed to `claude -p` as `--add-dir` flags. Path gating is separate from tool allow rules: a command matching an allow rule is still denied when it touches a path outside the working directory, so sibling repos, scratch areas, and package caches need to be listed here even when the account can already read them.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_ADD_DIRS` | *(empty)* | space-separated directory paths |

```bash
AGENT_ADD_DIRS="$HOME/repos/shared-assets $HOME/.cache/packages"
```

### AGENT_MEMORY_DIR

Path to a shared memory **directory** — an index plus the files its pointers name (the `~/.claude/projects/<slug>/memory/` layout). `AGENT_MEMORY_FILE` alone injects only the index, which for this layout is a table of contents for a book the agent cannot open: 25 one-line pointers to files the phase has no way to read.

When set:
- The index (`MEMORY.md` in the directory, or `AGENT_MEMORY_FILE` if also set) is injected via `--append-system-prompt` exactly as before.
- The directory is passed as `--add-dir`, so the phase can `Read` the file a pointer names — path gating would otherwise deny out-of-tree reads.
- The injected preamble names the directory and keeps memory **read-only**: only interactive sessions manage memory.

Supports absolute or workspace-relative paths. `AGENT_MEMORY_FILE` alone behaves exactly as before.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MEMORY_DIR` | *(empty)* | directory path (absolute or workspace-relative) |

```bash
AGENT_MEMORY_DIR="$HOME/.claude/projects/-home-user-repos-myproject/memory"
```

### AGENT_MEMORY_FILE

Path to a shared Claude memory file. If set and the file exists, its contents are appended to the system prompt for every `claude -p` invocation via `--append-system-prompt`. This lets the agent benefit from context accumulated during interactive Claude Code sessions.

Supports two path modes:
- **Absolute path**: Resolves directly (e.g., `$HOME/.claude/projects/.../memory/MEMORY.md`)
- **Workspace-relative path**: Resolves against the worktree directory (e.g., `claude-work/shared-memory.md`)

Workspace-relative paths enable **committed memory files** — a curated knowledge file checked into the repository that syncs across machines via git. See the [Customization Guide](customization.md#shared-project-memory) for setup details.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MEMORY_FILE` | *(empty)* | file path (absolute or workspace-relative) |

```bash
# Option 1: Machine-local memory (from interactive sessions on this machine)
AGENT_MEMORY_FILE="$HOME/.claude/projects/-home-user-repos-myproject/memory/MEMORY.md"

# Option 2: Committed memory file (shared across machines via git) — recommended
AGENT_MEMORY_FILE="claude-work/shared-memory.md"
```

The agent reads this file but never writes to it. Only interactive sessions should manage memory content.

### AGENT_TEST_COMMAND

A shell command to run as a pre-PR test gate. If set, the dispatch script runs this command after implementation and before creating the PR. If the tests fail, up to `AGENT_TEST_GATE_MAX_RETRIES` automated fix sessions attempt to get the suite green; if it still fails, the work branch is pushed, the failure comment links it, and the issue is labeled `agent:failed`. Re-applying `agent:plan-approved` resumes from the preserved branch.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TEST_COMMAND` | *(empty, gate skipped)* | shell command |

```bash
# Node.js
AGENT_TEST_COMMAND="npm test"

# Python
AGENT_TEST_COMMAND="pytest"

# Rust
AGENT_TEST_COMMAND="cargo test"

# Go
AGENT_TEST_COMMAND="go test ./..."
```

The test command is also referenced in the implement and review prompts as `$AGENT_TEST_COMMAND`, so the agent can run tests during its TDD cycles.

### AGENT_TEST_GATE_MAX_RETRIES

Maximum automated fix sessions when the pre-PR test gate fails. Each session is a fresh Claude run given the failing test output; the gate re-runs after each. A session that makes no commits ends the loop early (the failure is judged unfixable from inside the repo — e.g. a broken `AGENT_TEST_COMMAND`). Whatever happens, the work branch is pushed before `agent:failed` is set, so implementation work is never lost.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TEST_GATE_MAX_RETRIES` | `2` | non-negative integer (`0` = no fix sessions) |
| `AGENT_PROMPT_TEST_FIX` | *(empty, built-in `prompts/test-fix.md`)* | path |
| `AGENT_MODEL_TEST_FIX` | *(empty, uses worker model precedence above)* | model name |

### AGENT_EFFORT_LEVEL

The Claude Code effort level for all agent runs. Controls how much extended thinking Claude uses.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_EFFORT_LEVEL` | `high` | string (`low`, `medium`, `high`) |

```bash
AGENT_EFFORT_LEVEL="high"
```

This is exported as `CLAUDE_CODE_EFFORT_LEVEL` for the `claude` CLI.

### AGENT_ALLOW_DIRECT_IMPLEMENT

Controls whether the `agent:implement` label is accepted as an entry point. When enabled, humans can skip triage by adding `agent:implement` to an issue that already contains a complete plan. When disabled, the label is rejected and the issue is marked as failed.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_ALLOW_DIRECT_IMPLEMENT` | `true` | boolean string (`true` or `false`) |

```bash
# Enable (default) — allow agent:implement label
AGENT_ALLOW_DIRECT_IMPLEMENT="true"

# Disable — reject agent:implement label, require standard triage flow
AGENT_ALLOW_DIRECT_IMPLEMENT="false"
```

When disabled, any issue labeled with `agent:implement` will receive a comment explaining that direct implementation is not enabled and the label will be changed to `agent:failed`.

---

## Review Gates

Two independent, fresh-session review gates check the agent's work before it reaches a human: a pre-implementation plan review, and a capped post-implementation review loop.

### AGENT_ADVERSARIAL_PLAN_REVIEW

Before implementation starts, a fresh session checks the approved plan against the issue for gaps or misunderstandings.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_ADVERSARIAL_PLAN_REVIEW` | `true` | boolean string (`true` or `false`) |

```bash
AGENT_ADVERSARIAL_PLAN_REVIEW="false"   # disable pre-implementation plan review
```

### AGENT_POST_IMPL_REVIEW

After implementation, a fresh session checks the diff against the issue/plan. Set to `false` to skip straight to PR creation with no review loop at all.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_POST_IMPL_REVIEW` | `true` | boolean string (`true` or `false`) |

```bash
AGENT_POST_IMPL_REVIEW="false"   # disable post-implementation review entirely
```

If you override the review prompt via `AGENT_PROMPT_POST_IMPL_REVIEW` with a prompt that predates the ledger, a legacy `{"action":"concerns","concerns":["..."]}` response is still accepted: each string in `concerns` is mapped to a blocking finding when `.findings` is absent or empty.

### AGENT_POST_IMPL_REVIEW_MAX_RETRIES

Sets the cap on the ledger-driven review loop that gates PR creation: **review → fix → re-review**, repeated until the review comes back clean or the cap is hit. Each pass merges its findings into a ledger committed to the work branch at `.agent-data/review-ledger.json`, so the finding history and dispositions survive across retries and are visible in the branch's commit log.

- `0` = a single review pass with no fix loop — any open finding goes straight to an `agent:review-unresolved` PR.
- `N` (default `3`) = up to `N` fresh fix sessions, each followed by a fresh re-review pass, before giving up.

If the loop reaches the cap with findings still open, it does **not** block the PR: the PR opens anyway, labeled `agent:review-unresolved` **in addition to** `agent:pr-open`, with the outstanding findings summarized at the top of the PR body so a human reviewer sees them first.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` | `3` | integer (`0` = single pass, no retries) |

```bash
AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3   # default: up to 3 fix/re-review cycles
AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0   # single pass only, escalate any finding to a human
```

---

## Post-Merge Cleanup

When an agent-authored PR merges, an optional cleanup phase runs: tracking-doc updates and follow-up issues (sourced from the review ledger's structured output) are committed, and the merged branch is deleted.

### AGENT_CLEANUP_ENABLED

Enables the post-merge cleanup phase. When disabled, the doc-cleanup session is skipped for merged agent PRs.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_CLEANUP_ENABLED` | `true` | boolean string (`true` or `false`) |

```bash
AGENT_CLEANUP_ENABLED="false"   # disable post-merge cleanup
```

This flag gates only the doc-cleanup Claude session. The `agent:done` label
transition on linked issues runs for every merged agent PR regardless of
this setting — label bookkeeping is not cleanup.

### AGENT_PROMPT_CLEANUP

Custom prompt file for the cleanup session. If unset, the dispatch script uses the built-in `prompts/cleanup.md`.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_PROMPT_CLEANUP` | *(empty, uses `prompts/cleanup.md`)* | file path |

```bash
AGENT_PROMPT_CLEANUP="/home/user/my-project/agent-prompts/cleanup.md"
```

### AGENT_MODEL_CLEANUP

Per-workflow model override for the cleanup session. Empty follows the worker engine/model precedence documented above. Cleanup is bookkeeping (doc edits, issue filing), not implementation work, so a cheap/fast model is usually a good fit.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MODEL_CLEANUP` | *(empty)* | string (model name) |

```bash
AGENT_MODEL_CLEANUP="haiku"
```

### AGENT_ALLOWED_TOOLS_CLEANUP

Tools available during the cleanup session. Read-write by default (for doc edits and branch/label bookkeeping), same shape as `AGENT_ALLOWED_TOOLS_IMPLEMENT` but without a network-adjacent test-runner allowance.

| Key | Default |
|-----|---------|
| `AGENT_ALLOWED_TOOLS_CLEANUP` | `Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git rm:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*)` |

### Caller workflow

`sandbox-pal-post-merge.yml` is triggered by `pull_request.closed`, guarded to only fire for merged PRs authored by your bot:

```yaml
name: "Claude Agent: Post-Merge Cleanup"

on:
  pull_request:
    types: [closed]

jobs:
  post-merge-cleanup:
    if: >-
      github.event.pull_request.merged == true &&
      github.event.pull_request.user.login == 'my-bot'
    uses: your-org/sandbox-pal-action/.github/workflows/sandbox-pal-post-merge.yml@v1
    with:
      bot_user: "my-bot"
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      agent_pat: ${{ secrets.AGENT_PAT }}
```

---

## Tool Permissions

Tool permissions control which Claude Code tools the agent can use during each phase. They are written as `permissions.allow` and `permissions.deny` rules in the settings file each phase is launched with (`claude -p --settings`).

### AGENT_ALLOWED_TOOLS_TRIAGE

Tools available during triage and reply phases. These are read-only by default — the agent can explore the codebase but not modify files.

| Key | Default |
|-----|---------|
| `AGENT_ALLOWED_TOOLS_TRIAGE` | `Read,Grep,Glob,Bash(echo:*),Bash(cat:*),Bash(ls:*),Bash(find:*)` |

### AGENT_ALLOWED_TOOLS_IMPLEMENT

Tools available during implementation and review phases. These include write access for editing files and making git commits.

| Key | Default |
|-----|---------|
| `AGENT_ALLOWED_TOOLS_IMPLEMENT` | `Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*),Bash(mkdir:*)` |

Notable exclusions from the defaults:
- `git push` — handled by the dispatch script, not by Claude
- `sudo`, `rm -rf` — dangerous system operations
- `curl`, `wget` — network access (mitigates prompt injection from issue content)

### AGENT_EXTRA_TOOLS

Additional tools appended to the implementation toolset. Use this for project-specific build tools, test runners, or other commands the agent needs.

| Key | Default |
|-----|---------|
| `AGENT_EXTRA_TOOLS` | *(empty)* |

```bash
# Node.js project
AGENT_EXTRA_TOOLS="Bash(npm:*),Bash(npx:*)"

# Rust project
AGENT_EXTRA_TOOLS="Bash(cargo:*)"

# Python project
AGENT_EXTRA_TOOLS="Bash(pytest:*),Bash(pip:*)"
```

Extra tools are appended only to the implementation/review toolset, not to the triage toolset.

### AGENT_DISALLOWED_TOOLS

Tools to explicitly block. By default, MCP GitHub tools are blocked to avoid conflicts with the `gh` CLI that the dispatch script uses directly.

| Key | Default |
|-----|---------|
| `AGENT_DISALLOWED_TOOLS` | `mcp__github__*` |

```bash
AGENT_DISALLOWED_TOOLS="mcp__github__*"
```

---

## Custom Prompts

You can override the default prompts for each agent phase by pointing to your own prompt files. If unset, the dispatch script uses the built-in prompts from the `prompts/` directory.

| Key | Phase | Default prompt file |
|-----|-------|-------------------|
| `AGENT_PROMPT_TRIAGE` | Triage (new issue analysis) | `prompts/triage.md` |
| `AGENT_PROMPT_IMPLEMENT` | Implementation (code changes) | `prompts/implement.md` |
| `AGENT_PROMPT_REPLY` | Reply (follow-up to questions) | `prompts/reply.md` |
| `AGENT_PROMPT_REVIEW` | Review (PR feedback) | `prompts/review.md` |
| `AGENT_PROMPT_VALIDATE` | Validation (pre-written plan check) | `prompts/validate.md` |

```bash
AGENT_PROMPT_TRIAGE="/home/user/my-project/agent-prompts/triage.md"
AGENT_PROMPT_IMPLEMENT="/home/user/my-project/agent-prompts/implement.md"
```

See [customization.md](customization.md) for guidance on writing custom prompts.

---

## Path Settings

### AGENT_LOG_DIR

Directory where log files are written.

| Key | Default |
|-----|---------|
| `AGENT_LOG_DIR` | `$HOME/.claude/agent-logs` |

Two types of logs are written here:
- `sandbox-pal-dispatch.log` — main dispatch log (appended across all runs)
- `claude-stderr-<repo>-<issue>-<timestamp>.log` — stderr from each `claude -p` invocation

---

## Reusable Workflow Inputs

The reusable workflows (`sandbox-pal-triage.yml`, `sandbox-pal-implement.yml`, `sandbox-pal-reply.yml`, `sandbox-pal-review.yml`, `sandbox-pal-direct-implement.yml`, `sandbox-pal-post-merge.yml`) accept these inputs when called from your project's workflow:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `bot_user` | Yes | — | Bot account username (for self-trigger prevention in your calling workflow) |
| `dispatch_script` | No | `~/agent-infra/scripts/sandbox-pal-dispatch.sh` | Path to the dispatch script on the runner |
| `config_path` | No | `~/agent-infra/config.env` | Path to `config.env` on the runner |
| `timeout_minutes` | No | `125`¹ | GitHub Actions job timeout in minutes |
| `runner_labels` | No | `["self-hosted", "agent"]` | JSON array of runner labels for job placement |

¹ `sandbox-pal-post-merge.yml` is the exception: its `timeout_minutes` default is `30`, not `125` — cleanup is bookkeeping (doc commits, follow-up issue filing), not implementation work, so it doesn't need the longer default. `sandbox-pal-post-merge.yml` also accepts one extra input not needed by the other workflows:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `pr_number` | No | `''` (falls back to `github.event.pull_request.number`) | PR number override, for triggering the workflow via `repository_dispatch` instead of the standard `pull_request.closed` event |

All workflows also require the `agent_pat` secret — a fine-grained PAT for the bot account with repository read/write, issues, and pull requests permissions.

Example calling workflow:

```yaml
on:
  issues:
    types: [labeled]

jobs:
  triage:
    if: github.event.label.name == 'agent' && github.actor != 'my-bot'
    uses: your-org/sandbox-pal-action/.github/workflows/sandbox-pal-triage.yml@main
    with:
      bot_user: "my-bot"
      runner_labels: '["self-hosted", "agent"]'
    secrets:
      agent_pat: ${{ secrets.AGENT_PAT }}
```

---

## Phase Context Files

Before every phase the dispatch script writes what the phase needs to know into `.agent-data/context/` in the worktree. Prompts (default and custom) tell the agent to read these files with the Read tool. A value that is empty has no file. The directory is excluded from `git add` and is rebuilt for each phase.

### Issue Context (triage, reply, validate, implement and the review gates)

| File | Content |
|------|---------|
| `issue-title.txt` | Issue title |
| `issue-body.md` | Issue body (full markdown) |
| `comments.md` | Last 20 issue comments, formatted as `[author] body` |
| `issue-number.txt` | Issue number (implement and cleanup phases) |
| `plan.md` | The approved plan comment body (implement phase), or the issue body (direct implement) |
| `references/<number>.md` | One file per issue or pull request of this repository that the text refers to (`#123` or its URL): title, type, state and body. Bounded by `AGENT_CONTEXT_REFS_MAX` |

### Attached Data (validate, implement and review phases)

| File | Content |
|------|---------|
| `attached-data.md` | Index of what was downloaded: the path of the latest data comment, the paths of downloaded gist and attachment files, and the path of the download-errors file. Absent when nothing was attached |

### PR Context (review phase)

| File | Content |
|------|---------|
| `pr-title.txt` | PR title |
| `pr-body.md` | PR body/description |
| `reviews.md` | Review submissions, formatted as `[author] (state): body` |
| `review-comments.md` | Inline code comments, formatted as `[author] on file:line: body` |
| `pr-comments.md` | PR conversation comments, formatted as `[author]: body` |
| `commit-history.txt` | `git log --oneline origin/main..HEAD` on the PR branch |

### Gates and Cleanup

| File | Content |
|------|---------|
| `review-ledger.json` | The review findings ledger (post-implementation review, retry and cleanup) |
| `review-concerns.md` | The open blocking findings a retry session must address |
| `test-output.txt` | The last 100 lines of a failing test gate (test-fix phase) |
| `test-exit-code.txt` | That run's exit code |
| `merged-branch.txt` | The merged branch (cleanup phase) |

### Test Command

| File | Content |
|------|---------|
| `test-command.txt` | The test command from config (`AGENT_TEST_COMMAND`) |
| `test-setup-command.txt` | The setup command from config (`AGENT_TEST_SETUP_COMMAND`) |

### Environment Variables (deprecated)

The same values are still exported as `AGENT_*` environment variables (`AGENT_ISSUE_TITLE`, `AGENT_ISSUE_BODY`, `AGENT_COMMENTS`, `AGENT_PLAN_CONTENT`, `AGENT_PR_BODY` and the rest) for custom prompts written against them. They will be removed in a later release: reading one needs a shell command and an allow rule that matches it, which is the dependency the files remove. Move custom prompts to the files.

----------|---------|
| `$AGENT_ISSUE_TITLE` | Issue title |
| `$AGENT_ISSUE_BODY` | Issue body (full markdown) |
| `$AGENT_COMMENTS` | Last 20 issue comments, formatted as `[author] body` |
| `$AGENT_ISSUE_NUMBER` | Issue number (implement phase only) |
| `$AGENT_PLAN_CONTENT` | The approved plan comment body (implement phase), or the issue body (direct implement) |

### Debug Data (implement and review phases)

| Variable | Content |
|----------|---------|
| `$AGENT_DATA_COMMENT_FILE` | Path to the latest data comment saved as a file, or empty |
| `$AGENT_GIST_FILES` | Space-separated paths to downloaded gist/attachment files, or empty |
| `$AGENT_DATA_ERRORS` | Path to a file listing download failures, or empty |

### PR Context (review phase only)

| Variable | Content |
|----------|---------|
| `$AGENT_PR_TITLE` | PR title |
| `$AGENT_PR_BODY` | PR body/description |
| `$AGENT_REVIEWS` | Review submissions, formatted as `[author] (state): body` |
| `$AGENT_REVIEW_COMMENTS` | Inline code comments, formatted as `[author] on file:line: body` |
| `$AGENT_PR_COMMENTS` | PR conversation comments, formatted as `[author]: body` |
| `$AGENT_ISSUE_TITLE` | Linked issue title (if extractable from branch name) |
| `$AGENT_ISSUE_BODY` | Linked issue body |
| `$AGENT_COMMIT_HISTORY` | `git log --oneline origin/main..HEAD` on the PR branch |

### Test Command

| Variable | Content |
|----------|---------|
| `$AGENT_TEST_COMMAND` | The test command from config (available in prompts for TDD cycles) |

---

## Example Configurations

### Node.js Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_TEST_COMMAND="npm test"
AGENT_EXTRA_TOOLS="Bash(npm:*),Bash(npx:*),Bash(node:*)"
```

### Python Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_TEST_COMMAND="pytest -x --tb=short"
AGENT_EXTRA_TOOLS="Bash(pytest:*),Bash(python:*),Bash(pip:*)"
```

### Rust Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=300
AGENT_TIMEOUT=5400
AGENT_TEST_COMMAND="cargo test"
AGENT_EXTRA_TOOLS="Bash(cargo:*),Bash(rustc:*)"
```

### Godot / GDScript Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=600
AGENT_TIMEOUT=7200
AGENT_TEST_COMMAND="godot --headless --path . -s addons/gdUnit4/bin/GdUnitCmdTool.gd --add res://tests/unit --ignoreHeadlessMode"
AGENT_EXTRA_TOOLS="Bash(godot:*),Bash(Godot:*)"
AGENT_MEMORY_FILE="$HOME/.claude/projects/-home-user-repos-mygame/memory/MEMORY.md"
```

## Named dispatch profiles

Named profiles switch every phase together and restore your saved routing with
one command. They require explicit adoption of `AGENT_ENGINE_PROFILES=true`;
installation and update leave that mode disabled. First move any unqualified
Codex model/effort settings into their Codex namespaces as described in
[engine settings adoption](#retain-both-engines-settings). Existing Claude
fallbacks and both providers' authentication remain unchanged.

From the runtime directory, with `AGENT_CONFIG` pointing at your project's
existing config when using a reference installation:

```bash
# In your project config, after migrating legacy Codex settings:
# AGENT_ENGINE_PROFILES=true

# Only for a new catalog; -n preserves an existing custom catalog.
cp -n agent-profiles.example.json /path/to/project-config/agent-profiles.json
export AGENT_CONFIG=/path/to/project-config/config.env
scripts/agent-profile.sh capture my-hybrid
scripts/agent-profile.sh show my-hybrid
scripts/agent-profile.sh use codex-only
scripts/agent-profile.sh use claude-only
scripts/agent-profile.sh use my-hybrid

# Override this dispatch only:
AGENT_PROFILE=codex-only scripts/sandbox-pal-dispatch.sh implement owner/repo 123

# Restore ordinary AGENT_ENGINE / AGENT_ENGINE_<PHASE> routing:
scripts/agent-profile.sh use legacy
```

`capture NAME` saves the actual legacy engine routes, even while a named profile
is selected. It refuses an existing name and leaves selection and config files
intact. Models, effort, timeouts and Claude caps remain shared in the existing
config; capture saves routing, not a historical copy of those settings. If a
catalog already exists, add the two all-provider entries from
[`agent-profiles.example.json`](../agent-profiles.example.json) to its `profiles`
object without replacing your existing entries. Capture also works before
adoption, but selecting a named profile requires adoption.

`list` and `show [NAME] [--json]` are read-only and call neither GitHub nor
provider authentication. Show resolves all ten phases, displaying model (or
`CLI default`), effort, invocation timeout, applicable caps and source keys.
It validates settings for the engines those phases select; dispatch validates
only phases reachable by its event. Preview is not a provider availability or
quota check. `use NAME` validates the entire profile before atomically replacing
the saved selector and prints the preview. A failed switch preserves the prior
selection. Incoming `AGENT_PROFILE` still overrides a successful saved switch.

Selection precedence is:

1. Nonempty incoming `AGENT_PROFILE`, captured before sourcing Bash config.
2. Nonempty saved selection (default `.agent-profile`).
3. Nonempty `AGENT_PROFILE` from loaded config.
4. Catalog `default`, when present.
5. `legacy`.

Explicit `legacy` suppresses lower-priority selections. Empty selectors are
absent. This environment-first guarantee applies only to the new selector;
ordinary Bash config assignments keep their existing precedence.

A selected profile owns **all ten phase routes**, including reviews, retries,
test fixes and cleanup. Missing phase entries use its required `engine`, even
when old config or environment phase overrides remain set. `legacy` preserves
those old routes. Profiles never bypass human plan approval, independent review
sessions, test gates, locks or recovery.

The catalog is one JSON object with `version: 1`, an optional `default`, and a
`profiles` object. Names contain 1–64 ASCII letters, digits, underscores or
hyphens, start with a letter or digit, and cannot be `legacy`. For example:

```json
{
  "version": 1,
  "profiles": {
    "fast-codex": {
      "engine": "codex",
      "phases": {},
      "settings": {
        "AGENT_EFFORT_CODEX": "low",
        "AGENT_TIMEOUT_CODEX_IMPLEMENT": "5400"
      }
    },
    "hybrid": {
      "engine": "claude",
      "phases": {"POST_IMPL_REVIEW": "codex"},
      "settings": {}
    }
  }
}
```

Settings accept only existing engine-qualified `MODEL`, `EFFORT`, `TIMEOUT`,
and Claude `BUDGET_USD`, `PERMISSION_MODE`, `MAX_TURNS` keys, including their
phase variants. All values must be strings. Values overlay the same base keys,
then reuse engine+phase → engine default → documented legacy fallback → built-in
default resolution. An empty overlay masks that base key and inherits the next
level; `"false"` and `"0"` remain explicit values and fail when unsupported.
Unknown schema keys, phases, engines and unsupported controls are rejected.
No credentials, prompts, schemas, tests, authentication or review settings are
allowed in the catalog. Never put secrets in model identifiers or other settings
that appear in previews. Direct explicit-model calls retain their existing
precedence until preflight freezes a phase record.

`AGENT_PROFILES_FILE` defaults to `agent-profiles.json` and
`AGENT_PROFILE_STATE_FILE` to `.agent-profile`. Relative paths resolve against
the effective `CONFIG_DIR`: the last existing project config loaded by the
shared loader, or the runtime root if none exists. An existing custom
`AGENT_CONFIG` sets that directory; a missing custom config preserves the
existing dispatcher fallback to runtime `config.env`, then runtime defaults,
then runtime root. The helper uses the identical loading path. An explicitly
configured missing catalog, malformed catalog or selector, or unknown selected
profile fails without choosing another provider. An absent optional catalog
with no named selection retains legacy behavior.

Commit the non-sensitive catalog and any intended catalog default. Add
`.agent-profile` (or your custom state path) and `agent-profiles.json.lock/` to
the project's `.gitignore`. Selection writes use a temporary file in the same
directory and atomic rename. Concurrent switches leave one complete selection;
last successful replacement wins. Capture serializes catalog edits with a local
directory lock; retry after a competing capture finishes. If interrupted, remove
a leftover lock only after confirming that no capture is running.

Setup/update deliver and checksum the **example** catalog, helper and modules;
they do not create or replace the active catalog or selection. Repeated setup
also preserves existing config. The saved selection is local to that config
location, not a global account preference. Both interactive clients, standalone
Actions and reference Actions agree when pointed at the same config/state.
Other runners need the catalog/default distributed or an explicit selector.
Queued runs read selection when dispatch preflight starts. Already preflighted
runs retain the frozen profile and phase settings despite subsequent file edits.
There is no quota polling, automatic fallback, account switch or paid API
substitution.
