# Handoff: Deploy the Interactive Pipeline to this machine (Webber)

**Precondition:** sandbox-pal-action PR #72 (`feature/interactive-pipeline`) is MERGED to main.
**Execute in:** a fresh session, working across `~/repos/sandbox-pal-action` and `~/repos/Webber`.

## What this deployment is

Webber consumes sandbox-pal-action as a **standalone install committed to the Webber repo** at
`~/repos/Webber/.sandbox-pal-dispatch/` (scripts + prompts + labels.txt + tracked non-secret
`config.env`, `.upstream` tracking file). It is stale — version `2b6bcc6`, synced 2026-04-24 —
so the update pulls months of changes including the new review loop, `post_merge` event, and
cleanup phase. Machine secrets live in `~/agent-infra/config.env` (never print them).

## Steps

### 1. One Webber branch for the whole deployment

```bash
cd ~/repos/Webber && git checkout main && git pull origin main
git checkout -b chore/sandbox-pal-interactive-pipeline
```

### 2. Update the standalone install

```bash
cd ~/repos/sandbox-pal-action && git checkout main && git pull origin main
./scripts/update.sh ~/repos/Webber/.sandbox-pal-dispatch
```

`update.sh` verifies checksums from `.upstream`, warns on locally-modified files, and lists
NEW config vars (expect `AGENT_CLEANUP_ENABLED`, `AGENT_MODEL_CLEANUP`, `AGENT_PROMPT_CLEANUP`,
`AGENT_ALLOWED_TOOLS_CLEANUP`). It does not overwrite `config.env` (not in the checksum set).
Read its full output. Review `git -C ~/repos/Webber diff .sandbox-pal-dispatch` before committing.

### 3. Config edits (tracked `.sandbox-pal-dispatch/config.env`, non-secret)

- **`AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1` is currently pinned** — it would override the new
  loop default of 3. Either delete the line (adopt default 3) or set it explicitly. Ask Jonny
  if unsure; recommendation: delete the pin.
- Per-phase models (recommended in the PR #72 deployment notes):
  `AGENT_MODEL_IMPLEMENT=claude-opus-5`, `AGENT_MODEL_POST_IMPL_REVIEW=claude-fable-5`,
  `AGENT_MODEL_POST_IMPL_RETRY=claude-fable-5`, `AGENT_MODEL_REVIEW=claude-fable-5`,
  `AGENT_MODEL_CLEANUP=claude-haiku-4-5-20251001`.

### 4. Retire the project work-issue skill (deferred Task 11 — same branch)

```bash
git -C ~/repos/Webber rm -r .claude/skills/work-issue
```

Jonny chose (2026-08-01) to fold this into the next Webber branch instead of a standalone PR —
this branch is that branch. The project copy shadows the new global v2 at
`~/.claude/skills/work-issue/` (already installed). Memory:
`project_work_issue_v2_webber_deletion_pending` — delete that memory file once this merges.

### 5. Labels

```bash
cd ~/repos/sandbox-pal-action && ./scripts/create-labels.sh Frightful-Games/Webber
```

(Adds `agent:review-unresolved`. Frightful-Games uses the default gh token — no GH_TOKEN prefix.)

### 6. Commit + PR (Webber)

Conventional commits (e.g. `chore: sync .sandbox-pal-dispatch to interactive-pipeline` and the
`git rm` as its own `chore:` commit). Push, open the PR on Frightful-Games/Webber with the default
token. **Do NOT touch `.github/workflows/`** — see step 7.

### 7. HUMAN steps (Jonny — the session must NOT do these)

- Add the new caller workflow to Webber: copy
  `.claude/skills/setup/templates/standalone/sandbox-pal-post-merge.yml` from sandbox-pal-action
  to Webber `.github/workflows/sandbox-pal-post-merge.yml`, replacing `{{BOT_USER}}` with
  `strongbad-bot`. Convention: agent workflows in consuming repos are always added by the human.
- Merge the Webber PR.
- Optional: copy `skills/sp-*` from sandbox-pal-action to `~/.claude/skills/` (global fallback
  runners), and to Pompom alongside `work-issue`.

### 8. Verify

- After merge, arm a low-stakes test issue via `/work-issue` (now global v2): confirm the plan
  comment carries `<!-- agent-plan -->` + `<!-- agent-branch: ... -->`, the implement run builds
  on the pre-pushed branch, ledger commits (`chore(agent): review ledger — …`) appear on the work
  branch, and the PR body carries the Adversarial Review Ledger section.
- After merging that test PR: confirm the post-merge workflow fires (cleanup commits/labels).

## Gotchas

- The jnurre64 token file is `~/.config/gh-tokens/sandbox-pal-token` — the `claude-pal-token`
  name in `~/repos/CLAUDE.md` is stale. (Only needed for jnurre64 repos; Webber uses the default
  token.)
- `update.sh` aborts if `.upstream` is missing — it isn't (verified 2026-08-01).
- If `update.sh` flags locally-modified files in `.sandbox-pal-dispatch`, STOP and show Jonny the
  list before overwriting — local patches may predate upstream fixes.
- Do not run Webber test suites for this change (no GDScript touched); CI on the Webber PR is the
  gate.
