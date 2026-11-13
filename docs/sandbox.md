# Sandbox Profile

By default a phase runs as an ordinary process of the user who runs the dispatcher. Its tool allow list decides what it is asked to do, but does not contain it: an interpreter on the list runs anything, and the model's file tools can read whatever that user can read.

The `strict` profile contains it. Each Claude phase runs under Anthropic's [sandbox runtime](https://github.com/anthropics/sandbox-runtime) (`srt`), which on Linux uses bubblewrap to give the process its own view of the filesystem and a network that passes through an allowlisting proxy. The whole worker is inside: shell commands, the model's own Read, Edit and Write tools, hooks, and MCP servers.

It is off unless you turn it on. The limits of what it protects are in [security.md](security.md#sandbox-profile); read them before relying on it.

## Turning it on

In `config.defaults.env`:

```bash
AGENT_SANDBOX="${AGENT_SANDBOX:-strict}"
```

or for some phases only:

```bash
AGENT_SANDBOX_IMPLEMENT="strict"
AGENT_SANDBOX_TEST_FIX="strict"
```

`AGENT_SANDBOX_<PHASE>` overrides `AGENT_SANDBOX` in either direction, so one phase can also be taken out with `none`.

A profile that is asked for and cannot start fails the phase as a configuration error. No phase falls back to running unsandboxed.

## Prerequisites (Linux)

| Needs | Install |
|---|---|
| `srt` | `npm install -g @anthropic-ai/sandbox-runtime` |
| `bwrap` | the `bubblewrap` package |
| `socat` | the `socat` package |
| `rg` | the `ripgrep` package |

`scripts/check-prereqs.sh` reports which are missing and whether the sandbox can start.

**`srt` must be on the dispatcher's `PATH`**, or set `AGENT_SANDBOX_SRT` to its full path. An npm global `bin` directory is often on an interactive shell's `PATH` and not on a service's.

**Ubuntu 24.04 and later** restrict unprivileged user namespaces through AppArmor, and bubblewrap then fails with `loopback: Failed RTM_NEWADDR: Operation not permitted`. The fix is an AppArmor profile for bubblewrap, a root step:

```
# /etc/apparmor.d/bwrap
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
```

then `sudo systemctl reload apparmor`. Check with `scripts/check-prereqs.sh`.

macOS is supported by the runtime through its own mechanism but has not been tested with this pipeline.

## What a sandboxed phase can do

**Write** to:

- its worktree;
- the clone's `.git` directory, where a worktree's git data lives. `.git/hooks` and `.git/config` inside it are write-denied, since they would take effect outside the sandbox later;
- `/tmp`;
- the Claude config directory (`~/.claude`, or `CLAUDE_CONFIG_DIR`), except `settings.json`, `settings.local.json`, `CLAUDE.md`, `skills`, `plugins`, `commands`, `agents` and `hooks`;
- the paths in `AGENT_SANDBOX_ALLOW_WRITE`.

The dispatch log directory is write-denied even when it sits under the Claude directory.

**Read** everything the user can read, except:

- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`, `~/.config/gh`, `~/.config/gcloud`, `~/.config/git/credentials`;
- `.env` files in the worktree;
- the install's `config.env`;
- the phase token file;
- the paths in `AGENT_SANDBOX_DENY_READ`. **Put any directory where you keep tokens here.**

**Reach** these hosts, and no others:

- the model provider: `api.anthropic.com`, `*.anthropic.com`, `claude.ai`, `*.claude.ai`, `claude.com`, `*.claude.com`;
- GitHub: `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`;
- the hosts in `AGENT_SANDBOX_ALLOWED_DOMAINS`, for example `registry.npmjs.org` for a phase that installs packages.

Package registries are not allowed by default. A phase that runs `npm install` or `pip install` needs its registry added, or the dependencies installed beforehand by `AGENT_TEST_SETUP_COMMAND`, which runs outside the sandbox.

## Tool lists

Without a sandbox, the `Bash(...)` prefix rules in `AGENT_ALLOWED_TOOLS_*` and `AGENT_EXTRA_TOOLS` are the only limit on shell commands. They grow long, still refuse ordinary shell (a variable, a redirect, a loop), and usually include an interpreter, which allows anything.

Under `strict` the sandbox is the limit, so the dispatcher replaces every `Bash(...)` rule in a phase's list with one `Bash` rule:

| Configured | Used under `strict` |
|---|---|
| `Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(npm test)` | `Read,Edit,Write,Grep,Glob,Bash` |
| `Read,Grep,Glob` | `Read,Grep,Glob` (no shell is added) |

Rules for other tools are kept. `AGENT_DISALLOWED_TOOLS` still applies. A read-only phase keeps a list without `Edit`, but note that with shell access "read-only" is a convention the prompt sets, not something the list enforces; the same was true of any list with an interpreter on it.

Once a repo runs every phase under `strict`, the prefix rules in its config are unused and can be removed. `AGENT_SANDBOX_SHORT_TOOLS="false"` keeps the lists as written.

## What does not work inside

- **Services on the host.** The sandbox has its own loopback interface. A server on the host's `localhost`, or on the machine's own LAN address, is unreachable even when allowlisted. A server the phase starts itself is reachable from inside the same phase, so a phase can build, serve and test its own branch.
- **GPU devices.** `/dev` is fresh and holds no device nodes for a GPU. Tools that need one have to run outside a sandboxed phase.
- **Unix sockets**, unless `AGENT_SANDBOX_UNIX_SOCKETS="true"`. A virtual display (Xvfb) needs them. On a machine with a vendor GL driver, also force Mesa for the phase, because the vendor library fails without its device nodes. Put the variables in the `env` block of your `AGENT_SETTINGS_FILE`:

  ```json
  {
    "env": {
      "__EGL_VENDOR_LIBRARY_FILENAMES": "/usr/share/glvnd/egl_vendor.d/50_mesa.json",
      "__GLX_VENDOR_LIBRARY_NAME": "mesa"
    }
  }
  ```

- **`git push`, opening a pull request, labels, comments.** The dispatcher does these, outside the sandbox, as before.

## Git inside the sandbox

The runtime protects a set of file names in the working directory (shell profiles, `.gitconfig`, `.mcp.json`, editor directories and others) by mounting over them. Where such a file does not exist, the mount shows up inside the sandbox as an untracked path, and `git add -A` aborts on it. The dispatcher therefore gives the phase's git an excludes file listing those names, through `GIT_CONFIG_*` environment variables, after the contents of your own global excludes file. Nothing is written to the clone's configuration.

A consequence: a phase cannot add a new, previously untracked `.mcp.json`, `.gitmodules`, `.vscode` or `.idea` with `git add -A`. Tracked files of those names are unaffected.

## GitHub access from a phase

A sandboxed phase has no `gh` login and no dispatcher token. Issues and pull requests the issue text refers to are pre-fetched for it (`.agent-data/context/references/`). For anything beyond that, give phases a token of their own:

```bash
AGENT_PHASE_GH_TOKEN_FILE="/path/to/phase-readonly-token"
```

The file's content is exported to each phase as `GH_TOKEN`. Create a fine-grained token with read-only access to Contents, Issues, Pull requests and Actions on the repositories the pipeline works on, and keep the file mode `600`. See [security.md](security.md#the-phases-github-token).

This setting works with or without a sandbox profile.

## Verifying

`tests/test_sandbox_canary.bats` runs the real runtime with the configuration the dispatcher generates and checks that:

- a planted secret outside the worktree cannot be read;
- a request to a host off the allowlist fails;
- a write outside the worktree fails;
- `git add -A` and `git commit` work in a worktree;
- writes to the clone's `.git/hooks` and `.git/config` fail;
- the Claude settings file cannot be written.

It makes no model call. It is skipped where the runtime is not installed or cannot start.

```bash
AGENT_SANDBOX_SRT=/path/to/srt ./tests/bats/bin/bats tests/test_sandbox_canary.bats
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `The strict sandbox could not start: … RTM_NEWADDR: Operation not permitted` | The AppArmor restriction above. |
| `the strict sandbox profile needs: srt` | `srt` is not on the dispatcher's `PATH`. Set `AGENT_SANDBOX_SRT`. |
| `Sandbox dependencies not available: ripgrep (rg) not found` | Install `ripgrep`. A shell alias or function named `rg` is not enough. |
| `Read-only file system` from a build tool | The tool writes a cache outside the worktree. Add the directory to `AGENT_SANDBOX_ALLOW_WRITE`. |
| A package install or download hangs or fails | The host is not on the allowlist. Add it to `AGENT_SANDBOX_ALLOWED_DOMAINS`. |
| Xvfb exits at once | Set `AGENT_SANDBOX_UNIX_SOCKETS="true"` and the Mesa variables above. |
| `gh` says it is not logged in | Set `AGENT_PHASE_GH_TOKEN_FILE`. |
