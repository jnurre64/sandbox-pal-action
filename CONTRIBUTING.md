# Contributing

Thanks for your interest in contributing to sandbox-pal-action!

## How to Contribute

1. **Fork** the repository
2. **Create a branch** for your change: `git checkout -b my-feature`
3. **Make your changes** — follow the conventions below
4. **Run checks** before submitting:
   ```bash
   # ShellCheck (lint)
   shellcheck scripts/*.sh scripts/lib/*.sh

   # BATS tests (requires submodules)
   git submodule update --init
   ./tests/bats/bin/bats tests/
   ```
5. **Submit a pull request** with a clear description of what changed and why

## Conventions

- Shell scripts use `bash` with `set -euo pipefail`
- All scripts must pass [ShellCheck](https://www.shellcheck.net/) with zero warnings
- Use kebab-case for file names, SCREAMING_SNAKE_CASE for environment variables
- Keep functions focused — one clear purpose per function
- Add comments explaining "why", not "what"

## Testing

Tests use [BATS-Core](https://github.com/bats-core/bats-core) (Bash Automated Testing System) with [bats-assert](https://github.com/bats-core/bats-assert) and [bats-support](https://github.com/bats-core/bats-support). They're included as git submodules.

```bash
# First time: initialize submodules
git submodule update --init --recursive

# Run all tests
./tests/bats/bin/bats tests/

# Run a specific test file
./tests/bats/bin/bats tests/test_common.bats
```

### Test structure

| File | What it tests |
|------|--------------|
| `tests/test_common.bats` | Prompt loading, tool assembly, label detection, output parsing, logging, labels, circuit breaker, memory |
| `tests/test_defaults.bats` | Config loading, default values, overrides, required settings |
| `tests/test_data_fetch.bats` | Debug data extraction from comments, gist/attachment downloads, error handling |
| `tests/test_worktree.bats` | Git worktree management (source verification) |

### Writing new tests

Tests use a shared helper (`tests/helpers/test_helper.bash`) that provides:
- `setup()` / `teardown()` — creates/cleans temp directories, sets required env vars
- `create_mock "command" "output" [exit_code]` — creates mock executables that record their calls
- `get_mock_calls "command"` — retrieves what arguments a mock was called with

When adding a new feature, add a test that verifies the behavior. For bug fixes, add a regression test named `REGRESSION vX.Y.Z: description`.

## Versioning

This project follows [Semantic Versioning](https://semver.org/). See [docs/versioning.md](docs/versioning.md) for the full policy, including what counts as the public interface, when to release, and the release checklist.

## Reporting Issues

Open an issue with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, shell version, Claude Code version)

## Questions?

Open a discussion or issue — happy to help.
