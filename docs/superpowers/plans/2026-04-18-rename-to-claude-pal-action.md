# Rename `claude-agent-dispatch` → `claude-pal-action` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the GitHub repository and migrate the local clone, primary consumer (Webber), and systemd-managed bot services to the new name with no bot downtime exceeding ~1 minute and no breaking changes for downstream consumers.

**Architecture:** Operational migration in 8 ordered tasks. The GitHub rename (Task 2) is the cutover moment; everything before is reversible preflight, everything after relies on GitHub's permanent URL redirects to keep deferred consumers working. Eager migration covers only the renamed repo's own visible identity, the primary consumer Webber, and host infrastructure. Demo repos and historical doc references are deliberately deferred or excluded.

**Tech Stack:** Bash, git, `gh` CLI, systemd (`--user`), Python venv, sed.

**Spec:** `docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md`

**Pre-existing branch:** `spec/rename-to-claude-pal-action` already contains the design doc and this plan. Implementation work happens on this branch and additional branches off it as noted per task.

---

## Task 1: Preflight snapshot

Captures pre-rename state for rollback. Fully reversible — no production changes.

**Files:**
- Create: `/tmp/rename-snapshot/services-before.txt`
- Create: `/tmp/rename-snapshot/agent-dispatch-bot.service`
- Create: `/tmp/rename-snapshot/agent-dispatch-slack.service`
- Create: `/tmp/rename-snapshot/git-heads.txt`
- Create: `/tmp/rename-snapshot/open-prs-issues.txt`

- [ ] **Step 1: Create snapshot directory**

```bash
mkdir -p /tmp/rename-snapshot
```

Expected: directory created silently.

- [ ] **Step 2: Snapshot git HEADs**

```bash
{
  echo "claude-agent-dispatch HEAD: $(git -C ~/claude-agent-dispatch rev-parse HEAD)"
  echo "Webber HEAD: $(git -C ~/repos/Webber rev-parse HEAD)"
} > /tmp/rename-snapshot/git-heads.txt
cat /tmp/rename-snapshot/git-heads.txt
```

Expected: two lines printed, each with a 40-char SHA.

- [ ] **Step 3: Snapshot open PRs and issues on the dispatch repo**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr list --repo jnurre64/claude-agent-dispatch > /tmp/rename-snapshot/open-prs-issues.txt
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh issue list --repo jnurre64/claude-agent-dispatch >> /tmp/rename-snapshot/open-prs-issues.txt
cat /tmp/rename-snapshot/open-prs-issues.txt
```

Expected: list of open PRs and issues (may be empty; the snapshot file existing is what matters).

- [ ] **Step 4: Copy systemd unit files**

```bash
cp ~/.config/systemd/user/agent-dispatch-bot.service /tmp/rename-snapshot/
cp ~/.config/systemd/user/agent-dispatch-slack.service /tmp/rename-snapshot/
ls -la /tmp/rename-snapshot/
```

Expected: both `.service` files listed in the snapshot directory.

- [ ] **Step 5: Snapshot service status**

```bash
systemctl --user status agent-dispatch-bot agent-dispatch-slack > /tmp/rename-snapshot/services-before.txt 2>&1 || true
grep -E "Active:|Loaded:" /tmp/rename-snapshot/services-before.txt
```

Expected: `Active: active (running)` for both services.

- [ ] **Step 6: Verify no in-flight agent runs across consumer repos**

```bash
for repo in Frightful-Games/Webber Frightful-Games/dodge-the-creeps-demo Frightful-Games/recipe-manager-demo Frightful-Games/recipe-manager-setup-demo; do
  echo "=== $repo ==="
  gh issue list --repo "$repo" --label "agent:in-progress" --state open
done
```

Expected: each repo prints "no issues match your search" or empty list. If any in-progress label is found, **STOP** and wait for that run to complete before proceeding.

- [ ] **Step 7: Verify dispatch-cli-token PAT scope includes the repo**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh issue list --repo jnurre64/claude-agent-dispatch --limit 1
```

Expected: command succeeds (exit 0). May print one issue or "no issues match your search". A `401`/`403` response means the PAT scope is broken before we even start — fix at https://github.com/settings/personal-access-tokens before continuing.

---

## Task 2: GitHub repo rename (the cutover)

The irreversible-feeling moment. In practice: fully reversible by renaming back, but treat as a checkpoint.

**Files:** None (web UI action + verification).

- [ ] **Step 1: Open repo settings**

Navigate to: https://github.com/jnurre64/claude-agent-dispatch/settings

Expected: settings page loads.

- [ ] **Step 2: Rename**

In the "Repository name" field at the top, change `claude-agent-dispatch` to `claude-pal-action`. Click "Rename".

Expected: page reloads at `https://github.com/jnurre64/claude-pal-action/settings`.

- [ ] **Step 3: Verify new URL resolves**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh repo view jnurre64/claude-pal-action --json name,url
```

Expected: JSON output with `"name":"claude-pal-action"` and the new URL.

- [ ] **Step 4: Verify old URL redirects**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh repo view jnurre64/claude-agent-dispatch --json name,url
```

Expected: same JSON as Step 3 — `"name":"claude-pal-action"`. The `gh` CLI silently follows the redirect.

- [ ] **Step 5: Verify local fetch still works (pre-move)**

```bash
git -C ~/claude-agent-dispatch fetch
```

Expected: succeeds with no errors. The local clone's origin still points to the old URL; GitHub's redirect handles it.

- [ ] **Step 6: Verify branch protection ruleset survived**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh api repos/jnurre64/claude-pal-action/rulesets --jq '.[] | {id, name, enforcement}'
```

Expected: ruleset `main-protection` listed with `"enforcement":"active"`.

**Checkpoint:** if any of Steps 3-6 fail, rename back via the same Settings page. Total recovery: ~1 minute.

---

## Task 3: Visible-identity PR (clean cutover)

Minimal PR updating only user-facing identity surface so the repo's identity matches its new name within minutes of the rename.

**Files:**
- Modify: `~/claude-agent-dispatch/README.md` (4 occurrences: 3 badge URLs + 1 issues link, plus 2 `git clone` examples on lines 72 and 82)
- Modify: `~/claude-agent-dispatch/SECURITY.md:8` (advisory link)
- Modify: `~/claude-agent-dispatch/scripts/setup.sh:161` and `:360` (echoed help text)
- Modify: `~/claude-agent-dispatch/.github/ISSUE_TEMPLATE/config.yml:4` (docs URL)

- [ ] **Step 1: Branch from main**

```bash
cd ~/claude-agent-dispatch
git fetch origin
git checkout -b chore/rename-visible-identity origin/main
```

Expected: switched to new branch, working tree clean.

- [ ] **Step 2: Update README.md**

Replace all 5 occurrences of `jnurre64/claude-agent-dispatch` in `README.md` with `jnurre64/claude-pal-action`, and the title text on line 4 from `claude-agent-dispatch` to `claude-pal-action`:

```bash
sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g' README.md
sed -i 's|<h1 align="center">claude-agent-dispatch</h1>|<h1 align="center">claude-pal-action</h1>|' README.md
sed -i 's|alt="Claude Agent Dispatch"|alt="Claude Pal Action"|' README.md
```

Verify:

```bash
grep -n 'claude-agent-dispatch\|claude-pal-action\|Claude Agent Dispatch\|Claude Pal Action' README.md
```

Expected: only `claude-pal-action` and `Claude Pal Action` appear; no occurrences of the old name.

- [ ] **Step 3: Update SECURITY.md**

```bash
sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g' SECURITY.md
grep -n 'claude-agent-dispatch\|claude-pal-action' SECURITY.md
```

Expected: only `jnurre64/claude-pal-action` appears.

- [ ] **Step 4: Update scripts/setup.sh echoed text**

```bash
sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g' scripts/setup.sh
grep -n 'claude-agent-dispatch\|claude-pal-action' scripts/setup.sh
```

Expected: only `jnurre64/claude-pal-action` appears (2 occurrences, originally on lines 161 and 360).

- [ ] **Step 5: Update issue template config**

```bash
sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g' .github/ISSUE_TEMPLATE/config.yml
grep -n 'claude-agent-dispatch\|claude-pal-action' .github/ISSUE_TEMPLATE/config.yml
```

Expected: only `jnurre64/claude-pal-action` appears.

- [ ] **Step 6: Run ShellCheck on the modified script**

```bash
shellcheck scripts/setup.sh
```

Expected: no output (zero warnings, exit 0).

- [ ] **Step 7: Run BATS test suite**

```bash
./tests/bats/bin/bats tests/
```

Expected: all tests pass (sed only changed echoed strings; no logic affected).

- [ ] **Step 8: Commit**

```bash
git add README.md SECURITY.md scripts/setup.sh .github/ISSUE_TEMPLATE/config.yml
git commit -m "chore: update visible-identity references to claude-pal-action

Updates README badges/links, SECURITY.md advisory link, scripts/setup.sh
echoed help text, and issue template docs URL to reflect the new repo
name. Bulk doc sweep (docs/, .claude/, prompts/) follows in a separate PR.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Expected: commit created; branch ahead of origin/main by 1 commit.

- [ ] **Step 9: Push and open PR**

```bash
git push -u origin chore/rename-visible-identity
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr create \
  --repo jnurre64/claude-pal-action \
  --base main \
  --title "chore: update visible-identity references to claude-pal-action" \
  --body "Phase 2.5 of the rename: minimal PR updating README badges, SECURITY.md, setup.sh echoed text, and issue-template docs URL. Bulk doc sweep follows in a separate PR. See \`docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md\`."
```

Expected: PR URL printed.

- [ ] **Step 10: Wait for CI, then merge**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr checks --repo jnurre64/claude-pal-action --watch
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr merge --repo jnurre64/claude-pal-action --squash --delete-branch
```

Expected: checks pass (ShellCheck + BATS), merge succeeds, branch deleted.

---

## Task 4: Local clone migration + systemd update

Move the local clone to `~/repos/claude-pal-action/`, recreate Python venvs, update systemd units. Bot downtime budget: ~1 minute.

**Files:**
- Move: `~/claude-agent-dispatch/` → `~/repos/claude-pal-action/`
- Recreate: `~/repos/claude-pal-action/discord-bot/.venv/`
- Recreate: `~/repos/claude-pal-action/slack-bot/.venv/`
- Modify: `~/.config/systemd/user/agent-dispatch-bot.service` (`WorkingDirectory=` line)
- Modify: `~/.config/systemd/user/agent-dispatch-slack.service` (`WorkingDirectory=` line)

- [ ] **Step 1: Sync local clone with remote (pull merged Task 3 PR)**

```bash
cd ~/claude-agent-dispatch
git checkout main
git pull
```

Expected: working tree updated to include the visible-identity commit.

- [ ] **Step 2: Stop bot services**

```bash
systemctl --user stop agent-dispatch-bot agent-dispatch-slack
systemctl --user is-active agent-dispatch-bot agent-dispatch-slack || true
```

Expected: both report `inactive`.

- [ ] **Step 3: Move the clone**

```bash
mv ~/claude-agent-dispatch ~/repos/claude-pal-action
ls -d ~/repos/claude-pal-action ~/claude-agent-dispatch 2>&1
```

Expected: `~/repos/claude-pal-action` exists; `~/claude-agent-dispatch` reports "No such file or directory".

- [ ] **Step 4: Update git origin URL**

```bash
cd ~/repos/claude-pal-action
git remote set-url origin git@github.com-infra:jnurre64/claude-pal-action.git
git remote -v
git fetch
```

Expected: `git remote -v` shows the new URL; `git fetch` succeeds with no errors.

- [ ] **Step 5: Recreate Discord bot venv**

```bash
cd ~/repos/claude-pal-action/discord-bot
rm -rf .venv
python3 -m venv .venv
.venv/bin/pip install --quiet -r requirements.txt
.venv/bin/python -c "import discord; print(discord.__version__)"
```

Expected: pip install completes; discord.py version printed.

- [ ] **Step 6: Recreate Slack bot venv**

```bash
cd ~/repos/claude-pal-action/slack-bot
rm -rf .venv
python3 -m venv .venv
.venv/bin/pip install --quiet -r requirements.txt
.venv/bin/python -c "import slack_bolt; print(slack_bolt.version.__version__)"
```

Expected: pip install completes; slack_bolt version printed.

- [ ] **Step 7: Update systemd unit files**

```bash
sed -i 's|WorkingDirectory=/home/jonny/claude-agent-dispatch|WorkingDirectory=/home/jonny/repos/claude-pal-action|g' \
  ~/.config/systemd/user/agent-dispatch-bot.service \
  ~/.config/systemd/user/agent-dispatch-slack.service
grep WorkingDirectory ~/.config/systemd/user/agent-dispatch-bot.service ~/.config/systemd/user/agent-dispatch-slack.service
```

Expected: both files show `WorkingDirectory=/home/jonny/repos/claude-pal-action/...`.

- [ ] **Step 8: Reload systemd and start services**

```bash
systemctl --user daemon-reload
systemctl --user start agent-dispatch-bot agent-dispatch-slack
sleep 3
systemctl --user is-active agent-dispatch-bot agent-dispatch-slack
```

Expected: both report `active`.

- [ ] **Step 9: Inspect logs for startup errors**

```bash
journalctl --user -u agent-dispatch-bot -n 30 --no-pager
journalctl --user -u agent-dispatch-slack -n 30 --no-pager
```

Expected: each log shows successful startup (e.g., `Logged in as Pennyworth`, no Python tracebacks).

- [ ] **Step 10: Smoke test notifications**

Post a benign comment on a Frightful-Games demo issue (e.g., comment on an existing demo repo issue with text like "rename smoke test — please ignore"). The agent dispatch system should NOT trigger (no `agent:` label), but the bot's webhook handler may log the event.

Verify in Discord (`#bat-cave` channel) and Slack (`#bat-cave` channel) that subsequent dispatch notifications work by re-checking after the next legitimate consumer-repo workflow event. If no events occur within 1 hour, manually trigger a no-op via:

```bash
ISSUE=$(gh issue list --repo Frightful-Games/dodge-the-creeps-demo --limit 1 --json number --jq '.[0].number')
gh issue comment --repo Frightful-Games/dodge-the-creeps-demo "$ISSUE" --body "rename smoke test — please ignore"
```

(Plain `gh` here — Frightful-Games operations use the default pennyworth-bot token; the dispatch-cli-token is scoped to jnurre64/* only and would 403.)

Expected: bots remain healthy (`systemctl --user status` still active) regardless of whether a notification is triggered.

**Rollback path:** if Step 8 fails, restore `WorkingDirectory=` to the old path:
```bash
sed -i 's|WorkingDirectory=/home/jonny/repos/claude-pal-action|WorkingDirectory=/home/jonny/claude-agent-dispatch|g' ~/.config/systemd/user/agent-dispatch-{bot,slack}.service
mv ~/repos/claude-pal-action ~/claude-agent-dispatch
systemctl --user daemon-reload && systemctl --user start agent-dispatch-{bot,slack}
```

---

## Task 5: Webber consumer update

Update Webber's references to the dispatch repo. Webber is the only production consumer; demos defer to next `/update`.

**Files:**
- Modify: `~/repos/Webber/.agent-dispatch/.upstream` (line 3)
- Modify: `~/repos/Webber/.agent-dispatch/scripts/setup.sh` (lines 154, 342)
- Modify: `~/repos/Webber/docs/plans/agent-infra-repo.md` (~12 occurrences)
- Modify: `~/repos/Webber/.github/workflows/caller-dispatch.yml` (and any other `caller-*.yml` workflows that reference the dispatch repo)

- [ ] **Step 1: Branch in Webber**

```bash
cd ~/repos/Webber
git fetch origin
git checkout -b chore/rename-claude-pal-action origin/main
```

Expected: switched to new branch.

- [ ] **Step 2: Identify all Webber files referencing the old name**

```bash
git grep -l 'claude-agent-dispatch' || echo "none found"
```

Expected: list includes `.agent-dispatch/.upstream`, `.agent-dispatch/scripts/setup.sh`, `docs/plans/agent-infra-repo.md`, and one or more `.github/workflows/caller-*.yml` files. Note the exact list — Step 3 acts on it.

- [ ] **Step 3: Bulk replace in non-historical files**

```bash
git grep -l 'claude-agent-dispatch' \
  | grep -v '^docs/plans/agent-infra-repo.md$' \
  | xargs sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g; s|claude-agent-dispatch|claude-pal-action|g'
```

Expected: no errors. The `agent-infra-repo.md` plan doc is excluded because it documents the original infra-repo decision and references should be handled with a manual edit in Step 4.

- [ ] **Step 4: Update agent-infra-repo.md with a rename note**

Open `docs/plans/agent-infra-repo.md`. At the top of the file (after the existing title/header), add a note:

```markdown
> **Note (2026-04-18):** The infra repo was renamed from `jnurre64/claude-agent-dispatch` to `jnurre64/claude-pal-action`. References below preserve the original name as historical context; current setup uses the new name. See the dispatch repo's `docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md` for context.
```

Save the file. Do not bulk-replace the body — preserve historical accuracy.

- [ ] **Step 5: Verify replacement**

```bash
git grep 'claude-agent-dispatch'
```

Expected: only matches inside `docs/plans/agent-infra-repo.md` (the historical plan doc). All other files now reference `claude-pal-action`.

- [ ] **Step 6: Diff-review changed files**

```bash
git diff --stat
git diff
```

Expected: modifications limited to the files identified in Step 2 plus the new note in `agent-infra-repo.md`. No unintended changes.

- [ ] **Step 7: End-to-end smoke test on a demo repo**

Pick a throwaway demo issue. Apply the `agent:triage` label and verify the workflow runs. Use a demo repo, NOT Webber's main issue tracker:

```bash
gh issue create --repo Frightful-Games/dodge-the-creeps-demo \
  --title "Rename smoke test — please ignore" \
  --body "Triggering agent:triage to verify caller workflow resolves the renamed dispatch repo correctly. Auto-close after verification."
ISSUE=$(gh issue list --repo Frightful-Games/dodge-the-creeps-demo --limit 1 --json number --jq '.[0].number')
gh issue edit "$ISSUE" --repo Frightful-Games/dodge-the-creeps-demo --add-label "agent:triage"
gh run list --repo Frightful-Games/dodge-the-creeps-demo --limit 3
```

Expected: a workflow run starts within ~30s. Note: the demo repo's `caller-*.yml` still references the old name and resolves via redirect; this confirms the redirect path is healthy. Webber's caller will use the new name post-merge.

After verification, clean up:

```bash
gh issue close "$ISSUE" --repo Frightful-Games/dodge-the-creeps-demo --comment "Smoke test complete."
```

- [ ] **Step 8: Commit**

```bash
git add .agent-dispatch/ docs/plans/agent-infra-repo.md .github/workflows/
git commit -m "chore: update dispatch refs to claude-pal-action

Updates .agent-dispatch/.upstream, setup.sh echoed text, and
caller-*.yml workflow uses: refs to the renamed dispatch repo.
docs/plans/agent-infra-repo.md gets a top-of-file rename note;
its body preserves the original repo name as historical context.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Expected: commit created.

- [ ] **Step 9: Push and open PR**

```bash
git push -u origin chore/rename-claude-pal-action
gh pr create --repo Frightful-Games/Webber \
  --base main \
  --title "chore: update dispatch refs to claude-pal-action" \
  --body "Updates Webber's references to the renamed dispatch infra repo (\`jnurre64/claude-agent-dispatch\` → \`jnurre64/claude-pal-action\`). Demo repos will pick up the new name via their next \`/update\` skill run."
```

Expected: PR URL printed.

- [ ] **Step 10: Wait for CI, then merge**

```bash
gh pr checks --repo Frightful-Games/Webber --watch
gh pr merge --repo Frightful-Games/Webber --squash --delete-branch
```

Expected: checks pass, merge succeeds.

---

## Task 6: Bulk in-repo doc sweep

Low-pressure cleanup of remaining ~500 occurrences in the dispatch repo. Historical references in `docs/superpowers/plans/`, `docs/superpowers/specs/`, and `docs/plans/` are deliberately excluded.

**Files:** ~115 files in `~/repos/claude-pal-action/` excluding the three historical-doc directories.

- [ ] **Step 1: Branch from main**

```bash
cd ~/repos/claude-pal-action
git fetch origin
git checkout -b chore/rename-doc-sweep origin/main
```

Expected: branch created.

- [ ] **Step 2: List files that will change (dry run)**

```bash
git grep -l 'claude-agent-dispatch' \
  | grep -v '^docs/superpowers/plans/' \
  | grep -v '^docs/superpowers/specs/' \
  | grep -v '^docs/plans/' \
  | tee /tmp/rename-sweep-files.txt
wc -l /tmp/rename-sweep-files.txt
```

Expected: a list of files; the count gives a sense of sweep size (~50-80 files expected after Task 3 already handled the visible-identity ones).

- [ ] **Step 3: Apply replacement**

```bash
xargs sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g; s|claude-agent-dispatch|claude-pal-action|g' < /tmp/rename-sweep-files.txt
```

Expected: no errors.

- [ ] **Step 4: Verify only excluded directories still reference the old name**

```bash
git grep 'claude-agent-dispatch'
```

Expected: matches only inside `docs/superpowers/plans/`, `docs/superpowers/specs/`, and `docs/plans/`. If any other path appears, investigate (likely a noun-phrase variant like "agent dispatch" without the `claude-` prefix that the sed didn't catch — handle manually).

- [ ] **Step 5: Diff-review changed files**

```bash
git diff --stat | head -40
```

Spot-check several files with `git diff <path>` to confirm replacements are sane (e.g., URL replacements are full-form, no half-broken strings).

Expected: changes are mechanical name swaps, no logic affected.

- [ ] **Step 6: Run ShellCheck**

```bash
shellcheck scripts/*.sh scripts/lib/*.sh
```

Expected: no output (zero warnings).

- [ ] **Step 7: Run BATS**

```bash
./tests/bats/bin/bats tests/
```

Expected: all tests pass.

- [ ] **Step 8: Add CHANGELOG entry**

Edit `CHANGELOG.md`. Under the "Unreleased" section (or add one if absent), add:

```markdown
### Changed
- Repository renamed from `jnurre64/claude-agent-dispatch` to `jnurre64/claude-pal-action` (2026-04-18). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. See `docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md`.
```

Verify:

```bash
head -20 CHANGELOG.md
```

Expected: the new entry appears under Unreleased.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "chore: bulk doc sweep for claude-pal-action rename

Updates remaining in-repo references across docs, .claude/skills,
prompts, and other internal files. Historical references in
docs/superpowers/plans/, docs/superpowers/specs/, and docs/plans/
are deliberately preserved. Adds CHANGELOG entry for the rename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Expected: commit created.

- [ ] **Step 10: Push, open PR, wait for CI, merge**

```bash
git push -u origin chore/rename-doc-sweep
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr create \
  --repo jnurre64/claude-pal-action \
  --base main \
  --title "chore: bulk doc sweep for claude-pal-action rename" \
  --body "Phase 4.5 of the rename: bulk update of remaining ~500 in-repo references across docs and skills. Historical plan/spec docs preserved as-is. Adds CHANGELOG entry."
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr checks --repo jnurre64/claude-pal-action --watch
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr merge --repo jnurre64/claude-pal-action --squash --delete-branch
```

Expected: PR URL, checks pass, merge succeeds.

---

## Task 7: Memory updates

Update on-machine memory so future sessions reference the correct repo name and paths.

**Files:**
- Rename: `~/.claude/projects/-home-jonny/memory/project_claude_agent_dispatch.md` → `project_claude_pal_action.md`
- Modify: `~/.claude/projects/-home-jonny/memory/project_claude_pal_action.md` (post-rename)
- Modify: `~/.claude/projects/-home-jonny/memory/project_dispatch_notify.md`
- Modify: `~/.claude/projects/-home-jonny/memory/reference_github_finegrained_pat_collaborator.md`
- Modify: `~/.claude/projects/-home-jonny/memory/reference_dispatch_host_services.md`
- Modify: `~/.claude/projects/-home-jonny/memory/MEMORY.md`
- Create: `~/.claude/projects/-home-jonny/memory/reference_reserved_repo_name.md`

- [ ] **Step 1: Rename the project file**

```bash
cd ~/.claude/projects/-home-jonny/memory
mv project_claude_agent_dispatch.md project_claude_pal_action.md
ls project_claude_*.md
```

Expected: only `project_claude_pal_action.md` exists.

- [ ] **Step 2: Update frontmatter and body of the renamed file**

In `project_claude_pal_action.md`:

- Change frontmatter `name:` from `claude-agent-dispatch repository` to `claude-pal-action repository`
- Change frontmatter `description:` to `Reusable agent dispatch system extracted from Webber. Repo location, auth setup, current version, and key decisions. Renamed from claude-agent-dispatch on 2026-04-18.`
- Replace all `jnurre64/claude-agent-dispatch` with `jnurre64/claude-pal-action` in body
- Replace clone path `~/claude-agent-dispatch/` with `~/repos/claude-pal-action/`
- Replace SSH clone URL `git@github.com-infra:jnurre64/claude-agent-dispatch.git` with `git@github.com-infra:jnurre64/claude-pal-action.git`
- Update PAT scope description: `Scoped to jnurre64/claude-pal-action AND jnurre64/claude-pal`

Apply with sed for the bulk replacements:

```bash
sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g; s|~/claude-agent-dispatch/|~/repos/claude-pal-action/|g' project_claude_pal_action.md
```

Then manually edit the frontmatter `name:` and `description:` fields with a text editor.

Verify:

```bash
grep -E '^(name|description):' project_claude_pal_action.md
grep 'claude-agent-dispatch' project_claude_pal_action.md || echo "no remaining old-name references"
```

Expected: frontmatter reflects new name; no remaining `claude-agent-dispatch` strings.

- [ ] **Step 3: Update other memory files**

```bash
cd ~/.claude/projects/-home-jonny/memory
sed -i 's|jnurre64/claude-agent-dispatch|jnurre64/claude-pal-action|g; s|~/claude-agent-dispatch/|~/repos/claude-pal-action/|g; s|/home/jonny/claude-agent-dispatch|/home/jonny/repos/claude-pal-action|g' \
  project_dispatch_notify.md \
  reference_github_finegrained_pat_collaborator.md \
  reference_dispatch_host_services.md
```

Verify:

```bash
grep -l 'claude-agent-dispatch' *.md || echo "no files contain the old name"
```

Expected: "no files contain the old name" — except possibly the new `reference_reserved_repo_name.md` we add in Step 5, which legitimately references it.

- [ ] **Step 4: Update MEMORY.md index**

Edit `MEMORY.md`. Find the line:

```
- [project_claude_agent_dispatch.md](project_claude_agent_dispatch.md) — claude-agent-dispatch repo: location, auth, version, Webber standalone setup, key decisions
```

Replace with:

```
- [project_claude_pal_action.md](project_claude_pal_action.md) — claude-pal-action repo (renamed 2026-04-18 from claude-agent-dispatch): location, auth, version, Webber standalone setup, key decisions
```

Verify:

```bash
grep -E 'claude-(agent-dispatch|pal-action)' MEMORY.md
```

Expected: only the updated line, referencing `claude-pal-action`.

- [ ] **Step 5: Create reserved-name memory entry**

Create `~/.claude/projects/-home-jonny/memory/reference_reserved_repo_name.md`:

```markdown
---
name: Reserved GitHub repo name claude-agent-dispatch
description: The name jnurre64/claude-agent-dispatch is reserved post-rename — do not create a new repo with this name; doing so breaks the redirect that ~4 active references depend on.
type: reference
---

The name `jnurre64/claude-agent-dispatch` was renamed to `jnurre64/claude-pal-action` on 2026-04-18. GitHub redirects the old URL to the new one indefinitely, **unless** a new repo is created at the old name — at which point the redirect breaks and references resolve to the new (unrelated) repo.

**Active references that depend on the redirect:**
- Three demo repos (`Frightful-Games/dodge-the-creeps-demo`, `Frightful-Games/recipe-manager-demo`, `Frightful-Games/recipe-manager-setup-demo`) — their `.agent-dispatch/.upstream` and caller workflow `uses:` refs still point to the old URL until their next `/update` skill run.
- Public clone-URL examples in old social/blog posts and the original README's git history.
- Any external user who bookmarked the old repo URL.

**Action:** never create a new repo named `jnurre64/claude-agent-dispatch`. If you intend to start a different project, pick a different name.
```

Then add to `MEMORY.md`:

```bash
cat >> MEMORY.md <<'EOF'
- [reference_reserved_repo_name.md](reference_reserved_repo_name.md) — Don't reuse the name jnurre64/claude-agent-dispatch — breaks ~4 active redirect dependencies
EOF
```

Verify:

```bash
ls reference_reserved_repo_name.md
tail -5 MEMORY.md
```

Expected: file exists; new index line at the end of MEMORY.md.

- [ ] **Step 6: Sanity check — re-read MEMORY.md and confirm no broken links**

```bash
cat MEMORY.md
for f in $(grep -oE '\(\S+\.md\)' MEMORY.md | tr -d '()' ); do
  [ -f "$f" ] && echo "OK: $f" || echo "BROKEN: $f"
done
```

Expected: every referenced file shows `OK:`.

---

## Task 8: 24-hour cleanup

Final cleanup after sustained healthy operation.

**Files:**
- Delete: `/tmp/rename-snapshot/`

- [ ] **Step 1: Wait 24 hours from Task 4 completion**

No-op step. The waiting period gives time for any latent issue (PAT scope, redirect quirk, bot reconnection drift) to surface during normal operation.

- [ ] **Step 2: Verify bots still healthy**

```bash
systemctl --user is-active agent-dispatch-bot agent-dispatch-slack
journalctl --user -u agent-dispatch-bot -n 50 --no-pager | grep -iE 'error|exception' || echo "no errors"
journalctl --user -u agent-dispatch-slack -n 50 --no-pager | grep -iE 'error|exception' || echo "no errors"
```

Expected: both `active`; no errors in recent logs.

- [ ] **Step 3: Verify PAT-scoped operations still work**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh issue list --repo jnurre64/claude-pal-action --limit 1
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh issue list --repo jnurre64/claude-pal --limit 1
```

Expected: both succeed (exit 0).

- [ ] **Step 4: Delete the snapshot**

```bash
rm -rf /tmp/rename-snapshot
```

Expected: directory removed.

- [ ] **Step 5: Merge the spec branch**

The spec branch `spec/rename-to-claude-pal-action` (containing the design doc and this implementation plan) was created before the rename. Merge it into main now that the migration is complete:

```bash
cd ~/repos/claude-pal-action
git fetch origin
git checkout spec/rename-to-claude-pal-action
git rebase origin/main
git push -u origin spec/rename-to-claude-pal-action
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr create \
  --repo jnurre64/claude-pal-action \
  --base main \
  --title "docs: rename design + implementation plan" \
  --body "Captures the rename design and the executed implementation plan for posterity. Closes the rename project."
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr checks --repo jnurre64/claude-pal-action --watch
GH_TOKEN=$(cat ~/.config/gh-tokens/dispatch-cli-token) gh pr merge --repo jnurre64/claude-pal-action --squash --delete-branch
```

Expected: PR opens, checks pass, merge succeeds. Spec and plan now live on main as historical record.
