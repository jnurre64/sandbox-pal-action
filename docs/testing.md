# Testing

The project uses [BATS-Core](https://github.com/bats-core/bats-core) (Bash Automated Testing System) with [bats-assert](https://github.com/bats-core/bats-assert) and [bats-support](https://github.com/bats-core/bats-support) for unit and regression testing.

## Running Tests

```bash
# First time: initialize BATS submodules
git submodule update --init --recursive

# Run all tests
./tests/bats/bin/bats tests/

# Run a specific test file
./tests/bats/bin/bats tests/test_common.bats

# Run a specific test by name pattern
./tests/bats/bin/bats tests/ --filter "REGRESSION"
```

CI runs both ShellCheck and BATS on every push and PR to `main`.

## Test Suite Overview

52 tests across 4 test files, covering all lib modules and 5 regression tests.

### test_common.bats (24 tests)

Tests for `scripts/lib/common.sh` — the core shared functions.

#### Prompt Loading (6 tests)
| Test | What it verifies |
|------|-----------------|
| `load_prompt: loads custom prompt from absolute path` | Custom prompts are loaded when an absolute path is provided |
| `load_prompt: falls back to default prompt when custom path is empty` | Empty config falls back to built-in prompts in `prompts/` |
| `load_prompt: falls back to default prompt when custom file doesn't exist` | Missing custom file falls back gracefully |
| `REGRESSION v1.0.1: resolves relative paths against CONFIG_DIR` | Relative paths like `prompts/triage.md` resolve against the config file's directory, not the working directory |
| `REGRESSION v1.0.1: works with absolute paths regardless of CONFIG_DIR` | Absolute paths always work, even if CONFIG_DIR points elsewhere |
| `REGRESSION v1.0.1: falls back when CONFIG_DIR is empty` | Handles the case where no config directory is set |

#### Tool Assembly (3 tests)
| Test | What it verifies |
|------|-----------------|
| `get_implementation_tools: returns base tools when no extras` | Base toolset is returned cleanly |
| `get_implementation_tools: appends AGENT_EXTRA_TOOLS` | Project-specific tools (e.g., `Bash(npm:*)`) are appended |
| `get_implementation_tools: appends LABEL_EXTRA_TOOLS` | Label-triggered tools (e.g., from `agent:image-gen`) are appended |

#### Label-Based Tool Detection (2 tests)
| Test | What it verifies |
|------|-----------------|
| `detect_label_tools: sets LABEL_EXTRA_TOOLS when matching label found` | The `AGENT_LABEL_TOOLS_*` config correctly maps labels to tools |
| `detect_label_tools: LABEL_EXTRA_TOOLS empty when no matching labels` | No spurious tools added when labels don't match |

#### Claude Output Parsing (4 tests)
| Test | What it verifies |
|------|-----------------|
| `parse_claude_output: extracts result from json` | Normal success response parsed correctly |
| `parse_claude_output: extracts result_text on error` | Error/timeout responses parsed correctly |
| `parse_claude_output: returns subtype when no result fields` | Subtype-only responses handled gracefully |
| `parse_claude_output: returns raw input when not json` | Non-JSON output passed through unchanged |

#### PR Body (1 test)
| Test | What it verifies |
|------|-----------------|
| `REGRESSION v1.0.5: PR body template does not contain ### Summary heading` | Prevents duplicate Summary headings (Claude's output already includes one) |

#### Test Gate (2 tests)
| Test | What it verifies |
|------|-----------------|
| `REGRESSION v1.0.3: test setup command present in handle_post_implementation` | `AGENT_TEST_SETUP_COMMAND` is checked before running tests |
| `REGRESSION v1.0.3: test setup runs before test command in source` | Setup command appears before test command in the code flow |

#### Logging (2 tests)
| Test | What it verifies |
|------|-----------------|
| `log: writes timestamped message to log file` | Messages are written to `sandbox-pal-dispatch.log` |
| `log: includes event type and issue number` | Log lines contain `[event_type] #number` for filtering |

#### Label Management (1 test)
| Test | What it verifies |
|------|-----------------|
| `set_label: calls gh to add label` | Labels are set via `gh issue edit --add-label` |

#### Circuit Breaker (1 test)
| Test | What it verifies |
|------|-----------------|
| `check_circuit_breaker: passes when below limit` | Normal operation when comment count is under the threshold |

#### Shared Memory (2 tests)
| Test | What it verifies |
|------|-----------------|
| `load_shared_memory: returns empty when no memory file` | No crash when memory is unconfigured |
| `load_shared_memory: loads memory file content` | Memory file content is wrapped with header and returned |

---

### test_defaults.bats (11 tests)

Tests for `scripts/lib/defaults.sh` and dispatch script configuration.

#### Config Loading (3 tests)
| Test | What it verifies |
|------|-----------------|
| `defaults.sh: fails when AGENT_BOT_USER is not set` | Clear error when required config is missing |
| `defaults.sh: uses default values when not overridden` | MAX_TURNS=200, TIMEOUT=3600, CIRCUIT_BREAKER=8 |
| `defaults.sh: config.env values override defaults` | User config takes precedence over defaults |

#### Triage Toolset (2 tests)
| Test | What it verifies |
|------|-----------------|
| `REGRESSION v1.0.2: triage toolset includes Write tool` | `Write` is in the triage toolset (needed for plan file output) |
| `REGRESSION v1.0.2: triage toolset includes Read and Grep` | Core read tools are present |

#### Test Setup Command (2 tests)
| Test | What it verifies |
|------|-----------------|
| `REGRESSION v1.0.3: AGENT_TEST_SETUP_COMMAND defaults to empty` | No setup command by default (optional) |
| `REGRESSION v1.0.3: AGENT_TEST_SETUP_COMMAND can be set via config` | Config value is respected |

#### Label-Tool Mapping (1 test)
| Test | What it verifies |
|------|-----------------|
| `defaults.sh: documents label-to-tool mapping pattern` | `AGENT_LABEL_TOOLS_` pattern is documented in source |

#### Dispatch Config (1 test)
| Test | What it verifies |
|------|-----------------|
| `dispatch script: sets CONFIG_DIR when sourcing config` | CONFIG_DIR is set to the config file's parent directory |

#### Retry Detection (2 tests)
| Test | What it verifies |
|------|-----------------|
| `REGRESSION v1.0.4: handle_implement uses origin/main for start_sha` | Compares against origin/main to detect ALL implementation commits |
| `REGRESSION v1.0.4: handle_implement does NOT use rev-parse HEAD` | HEAD would miss commits from previous failed runs |

---

### test_data_fetch.bats (11 tests)

Tests for `scripts/lib/data-fetch.sh` — debug data extraction from issue/PR comments.

#### Data Extraction (6 tests)
| Test | What it verifies |
|------|-----------------|
| `extract_debug_data: sets empty globals when no data found` | Clean state when no debug data exists |
| `extract_debug_data: creates data directory` | Auto-creates the `.agent-data/` directory |
| `extract_debug_data: finds submit-logs comment by Environment marker` | Detects the `### Environment` marker from `/submit-logs` |
| `extract_debug_data: skips bot comments` | Bot's own comments are not treated as debug data |
| `extract_debug_data: finds gist links in comments` | Gist URLs are detected and download is attempted |
| `extract_debug_data: checks extra_text for attachments` | Issue/PR body is also scanned for data links |

#### Gist Download (3 tests)
| Test | What it verifies |
|------|-----------------|
| `_download_linked_files: extracts and downloads gist URLs` | Single gist download creates the expected file |
| `_download_linked_files: handles multiple gist URLs` | Multiple gists in the same text are all downloaded |
| `_download_linked_files: records errors for failed downloads` | Failed downloads are recorded in the errors file |

#### Source Verification (2 tests)
| Test | What it verifies |
|------|-----------------|
| `data-fetch.sh: handles attachment URLs` | GitHub user-attachment URLs are supported |
| `data-fetch.sh: validates downloaded files aren't error pages` | Checks for "Not Found" / HTML error pages in downloads |

---

### test_worktree.bats (6 tests)

Tests for `scripts/lib/worktree.sh` — source-level verification (git operations require real repos, so these verify code structure rather than running commands).

| Test | What it verifies |
|------|-----------------|
| `worktree.sh: defines ensure_repo function` | Function exists and is loadable |
| `worktree.sh: defines setup_worktree function` | Function exists and is loadable |
| `worktree.sh: defines cleanup_worktree function` | Function exists and is loadable |
| `worktree.sh: setup_worktree prunes stale worktrees` | `worktree prune` is called (prevents stale ref locks) |
| `worktree.sh: setup_worktree checks for remote branch` | Checks `ls-remote` before creating (reuses existing branches) |
| `worktree.sh: cleanup_worktree uses --force` | Force removal prevents errors from dirty worktrees |

---

## Regression Tests

Each bug found during Phase 4 testing has a dedicated regression test to prevent recurrence:

| Version | Bug | Test name |
|---------|-----|-----------|
| v1.0.1 | Relative prompt paths resolved against cwd instead of config dir | `REGRESSION v1.0.1: resolves relative paths against CONFIG_DIR` |
| v1.0.2 | Triage toolset missing `Write` (agent couldn't save plan file) | `REGRESSION v1.0.2: triage toolset includes Write tool` |
| v1.0.3 | No pre-test setup command (Godot cache missing in fresh worktrees) | `REGRESSION v1.0.3: test setup command present` + `runs before test command` |
| v1.0.4 | Retry compared against HEAD instead of origin/main (missed existing commits) | `REGRESSION v1.0.4: uses origin/main` + `does NOT use HEAD` |
| v1.0.5 | PR body had duplicate Summary heading | `REGRESSION v1.0.5: PR body template does not contain ### Summary` |

## Test Helpers

The shared helper at `tests/helpers/test_helper.bash` provides:

### setup() / teardown()
Automatically called before/after each test. Creates a temp directory (`$TEST_TEMP_DIR`), sets all required environment variables, and cleans up after.

### create_mock "command" "output" [exit_code]
Creates a mock executable in the PATH that:
- Returns the specified output
- Exits with the specified code (default: 0)
- Records all calls to a file for later inspection

```bash
create_mock "gh" "3"  # gh will output "3" and exit 0
create_mock "gh" "" 1  # gh will output nothing and exit 1
```

### get_mock_calls "command"
Returns all recorded invocations of a mock, one per line. Useful for verifying that the right commands were called with the right arguments.

```bash
create_mock "gh" ""
set_label "agent:triage"
calls=$(get_mock_calls "gh")
[[ "$calls" == *"add-label"* ]]  # verify gh was called with --add-label
```

## Writing New Tests

1. Put tests in `tests/test_<module>.bats`
2. Load the helper: `load 'helpers/test_helper'`
3. Source the module you're testing (after `setup()` runs)
4. Use `create_mock` for external commands (`gh`, `git`, `claude`)
5. Use `run` + `assert_*` for testing function output
6. For bug fixes, name the test `REGRESSION vX.Y.Z: description`
