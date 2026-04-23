# Rename to sandbox-pal-action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the project from `claude-pal-action` to `sandbox-pal-action` everywhere it appears in-tree, and rewrite outward-facing identity copy (README tagline, image alt text, GitHub repo description, notification footers) so the project identity no longer carries the "Claude" brand name. The GitHub repository rename itself happens out-of-band after this PR merges.

**Architecture:** Mechanical text sweep across the 35 in-tree files that reference `claude-pal-action`, plus targeted rewrites on a small number of *identity* surfaces where the current copy says "for Claude Code" as part of the project's outward pitch. Deep product/CLI references to "Claude Code" in docs and prompts are left alone — the underlying agent is still Claude Code today, and stripping those references is a separate effort. Historical artifacts under `docs/superpowers/plans/` and `docs/superpowers/specs/` are not touched; they are point-in-time records of prior work.

**Tech Stack:** Bash (scripts + BATS tests), Python 3 (discord-bot, slack-bot, shared package), GitHub Actions reusable workflows, Markdown docs, `shellcheck`.

## Scope Decisions (locked in conversation)

- **Narrow rename + targeted identity rewrite.** Replace every `claude-pal-action` string with `sandbox-pal-action`. Also rewrite the README image alt text, the README tagline, the GitHub repo description, and the notification footer wording so they read model-agnostically. Leave "Claude Code" product/CLI references intact elsewhere (authentication docs, prompt bodies, README feature bullets).
- **No version bump.** Precedent: the 2026-04-18 `claude-agent-dispatch` → `claude-pal-action` rename was also no-bump.
- **Historical superpowers plans/specs untouched.** Leaves the paper trail accurate as a point-in-time record. Confirmed with user.
- **Downstream consumers handled separately.** Webber (personal consumer repo on this machine, different PAT), `recipe-manager-demo`, `dodge-the-creeps-demo` — not in scope of this PR. Captured as post-merge follow-up.
- **Branch already exists:** `chore/rename-to-sandbox-pal-action` off latest `main`.

## Proposed Identity Copy

Locked-in replacement text for identity surfaces. Reused verbatim in the tasks below.

**GitHub repo description (post-merge, set via GitHub UI or `gh repo edit`):**
> *Reusable agent dispatch system — label-driven GitHub Actions workflows for issue triage, planning, implementation, and PR review.*

**README image alt text (`README.md:2`):** `Sandbox Pal Action`

**README tagline (`README.md:11`, full replacement of the paragraph):**
> *A reusable dispatch system for running AI coding agents on GitHub issues — triaging, planning, implementing, and addressing PR review feedback, all orchestrated through GitHub Actions and a label-driven state machine.*

**Notification footer (`scripts/lib/notify.sh`, `discord-bot/bot.py`, `slack-bot/bot.py`, and their tests):**
> `Automated by sandbox-pal-action`

## File Inventory

Full set of in-tree files to update (35 total, authoritative as of 2026-04-23 from a `grep -rln` sweep with historical + vendored paths excluded):

**Setup skill templates (9):**
- `.claude/skills/setup/templates/caller-cleanup.yml`
- `.claude/skills/setup/templates/caller-direct-implement.yml`
- `.claude/skills/setup/templates/caller-dispatch.yml`
- `.claude/skills/setup/templates/caller-implement.yml`
- `.claude/skills/setup/templates/caller-reply.yml`
- `.claude/skills/setup/templates/caller-review.yml`
- `.claude/skills/setup/templates/caller-triage.yml`
- `.claude/skills/setup/templates/standalone/agent-dispatch.yml`
- `.claude/skills/setup/SKILL.md`

**Update skill (1):**
- `.claude/skills/update/SKILL.md`

**Scripts (3):**
- `scripts/check-prereqs.sh`
- `scripts/setup.sh`
- `scripts/lib/notify.sh`

**Notification bots + tests (7):**
- `discord-bot/bot.py`
- `discord-bot/tests/test_embeds.py`
- `slack-bot/bot.py`
- `slack-bot/tests/test_blocks.py`
- `shared/dispatch_bot/__init__.py`
- `tests/test_notify.bats`
- `tests/test_update.bats`

**Top-level project docs (5):**
- `README.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `.github/ISSUE_TEMPLATE/config.yml`

**`docs/` sweep (10):**
- `docs/bot-account.md`
- `docs/configuration.md`
- `docs/customization.md`
- `docs/getting-started.md`
- `docs/notifications.md`
- `docs/operations.md`
- `docs/runners.md`
- `docs/versioning.md`
- `docs/issues/adversarial-prompts-need-json-only-reinforcement.md`
- `docs/issues/err-trap-double-report-on-controlled-failures.md`

---

## Task 1: Baseline enumeration — freeze the expected file set

**Files:** None modified. Produces a verification anchor.

- [ ] **Step 1: Run the authoritative scope grep and save the file list**

```bash
grep -rln "claude-pal-action" \
  --include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" \
  --include="*.env*" --include="*.json" --include="*.py" --include="*.toml" \
  --include="*.bats" \
  . 2>/dev/null \
  | grep -v "^\./docs/superpowers/plans/\|^\./docs/superpowers/specs/\|^\./\.worktrees/\|^\./\.git/\|\.venv/" \
  | sort > /tmp/sandbox-rename-before.txt

wc -l /tmp/sandbox-rename-before.txt
```

Expected: `35 /tmp/sandbox-rename-before.txt`. If a different count comes back, stop and reconcile — the file inventory above is a snapshot; recheck before editing anything.

- [ ] **Step 2: Snapshot the total occurrence count for post-sweep verification**

```bash
grep -rcn "claude-pal-action" \
  --include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" \
  --include="*.env*" --include="*.json" --include="*.py" --include="*.toml" \
  --include="*.bats" \
  . 2>/dev/null \
  | grep -v "^\./docs/superpowers/plans/\|^\./docs/superpowers/specs/\|^\./\.worktrees/\|^\./\.git/\|\.venv/" \
  | awk -F: '{s+=$2} END {print s}' > /tmp/sandbox-rename-count-before.txt

cat /tmp/sandbox-rename-count-before.txt
```

Writes a single integer (expected range: 60–90 occurrences across 35 files) to `/tmp/sandbox-rename-count-before.txt`. Recorded so Task 9 can confirm the post-sweep count is zero.

- [ ] **Step 3: No commit**

Pure reconnaissance — nothing to commit.

---

## Task 2: Rename in setup skill caller templates

These templates are copied verbatim into consumer repos when a user runs `/setup`. They carry `uses: jnurre64/claude-pal-action/...@v1` lines and one `concurrency.group` name. Fixing these is the single highest-leverage change — new consumers from today onward get the correct reference.

**Files:**
- Modify: `.claude/skills/setup/templates/caller-cleanup.yml`
- Modify: `.claude/skills/setup/templates/caller-direct-implement.yml`
- Modify: `.claude/skills/setup/templates/caller-dispatch.yml`
- Modify: `.claude/skills/setup/templates/caller-implement.yml`
- Modify: `.claude/skills/setup/templates/caller-reply.yml`
- Modify: `.claude/skills/setup/templates/caller-review.yml`
- Modify: `.claude/skills/setup/templates/caller-triage.yml`
- Modify: `.claude/skills/setup/templates/standalone/agent-dispatch.yml`

- [ ] **Step 1: Replace the project-name string in all caller templates**

```bash
cd /home/jonny/repos/claude-pal-action

sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  .claude/skills/setup/templates/caller-cleanup.yml \
  .claude/skills/setup/templates/caller-direct-implement.yml \
  .claude/skills/setup/templates/caller-dispatch.yml \
  .claude/skills/setup/templates/caller-implement.yml \
  .claude/skills/setup/templates/caller-reply.yml \
  .claude/skills/setup/templates/caller-review.yml \
  .claude/skills/setup/templates/caller-triage.yml \
  .claude/skills/setup/templates/standalone/agent-dispatch.yml
```

- [ ] **Step 2: Verify no old name remains in this set**

```bash
grep -n "claude-pal-action" .claude/skills/setup/templates/ -r
```

Expected: no output (exit status 1).

- [ ] **Step 3: Verify the YAML still parses**

```bash
for f in .claude/skills/setup/templates/caller-*.yml \
         .claude/skills/setup/templates/standalone/agent-dispatch.yml; do
  python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" && echo "OK: $f"
done
```

Expected: one `OK: <path>` line per file, no Python tracebacks.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/setup/templates/
git commit -m "chore(setup-templates): rename uses/group refs to sandbox-pal-action"
```

---

## Task 3: Rename in setup and update skill docs

These Markdown files tell new users how to install the project and tell existing standalone users how to pull updates. They carry clone URLs, example `uses:` lines, and repo references embedded in example YAML.

**Files:**
- Modify: `.claude/skills/setup/SKILL.md`
- Modify: `.claude/skills/update/SKILL.md`

- [ ] **Step 1: Replace the project-name string**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  .claude/skills/setup/SKILL.md \
  .claude/skills/update/SKILL.md
```

- [ ] **Step 2: Verify**

```bash
grep -n "claude-pal-action" .claude/skills/setup/SKILL.md .claude/skills/update/SKILL.md
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/setup/SKILL.md .claude/skills/update/SKILL.md
git commit -m "chore(skills): rename clone URLs and examples to sandbox-pal-action"
```

---

## Task 4: Rename in shell scripts

`scripts/setup.sh` and `scripts/check-prereqs.sh` carry banner strings and example clone URLs. `scripts/lib/notify.sh` carries the literal notification footer — that footer change is covered more carefully in Task 5 alongside its BATS test, so this task stops short of touching the footer.

**Files:**
- Modify: `scripts/check-prereqs.sh`
- Modify: `scripts/setup.sh`

- [ ] **Step 1: Replace the project-name string in setup + prereq scripts (not notify.sh yet)**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  scripts/check-prereqs.sh \
  scripts/setup.sh
```

- [ ] **Step 2: Verify and run shellcheck**

```bash
grep -n "claude-pal-action" scripts/check-prereqs.sh scripts/setup.sh
shellcheck scripts/check-prereqs.sh scripts/setup.sh
```

Expected: no grep output; shellcheck returns zero warnings.

- [ ] **Step 3: Commit**

```bash
git add scripts/check-prereqs.sh scripts/setup.sh
git commit -m "chore(scripts): rename banner/clone-URL references to sandbox-pal-action"
```

---

## Task 5: Rename the notification footer (TDD cycle)

The string `Automated by claude-pal-action` is user-visible in every Slack/Discord notification the bots send. Three implementations emit it (`scripts/lib/notify.sh`, `discord-bot/bot.py`, `slack-bot/bot.py`), and three tests assert it (`tests/test_notify.bats`, `discord-bot/tests/test_embeds.py`, `slack-bot/tests/test_blocks.py`). Update tests first so they fail, then fix the implementations.

**Files:**
- Modify: `tests/test_notify.bats`
- Modify: `discord-bot/tests/test_embeds.py`
- Modify: `slack-bot/tests/test_blocks.py`
- Modify: `scripts/lib/notify.sh`
- Modify: `discord-bot/bot.py`
- Modify: `slack-bot/bot.py`
- Modify: `shared/dispatch_bot/__init__.py` (docstring only — cosmetic)

- [ ] **Step 1: Update all three test files to assert the new footer**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  tests/test_notify.bats \
  discord-bot/tests/test_embeds.py \
  slack-bot/tests/test_blocks.py
```

- [ ] **Step 2: Run the BATS notify test — expect it to fail**

```bash
./tests/bats/bin/bats tests/test_notify.bats
```

Expected: one or more failing assertions of the form `expected: "...sandbox-pal-action..." got: "...claude-pal-action..."`. If the test passes on the first run, stop — either the sed missed or the implementation was already renamed.

- [ ] **Step 3: Update `scripts/lib/notify.sh` footer string**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' scripts/lib/notify.sh
```

- [ ] **Step 4: Re-run BATS — expect pass**

```bash
./tests/bats/bin/bats tests/test_notify.bats
```

Expected: all tests in `test_notify.bats` pass.

- [ ] **Step 5: Update the Python bots and shared package**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  discord-bot/bot.py \
  slack-bot/bot.py \
  shared/dispatch_bot/__init__.py
```

- [ ] **Step 6: Run the Python test suites**

```bash
cd discord-bot && .venv/bin/python -m pytest tests/test_embeds.py -v && cd ..
cd slack-bot && .venv/bin/python -m pytest tests/test_blocks.py -v && cd ..
```

Expected: both suites green. If the venvs are missing on this machine, note that and defer to CI — do not skip the change.

- [ ] **Step 7: Also update `tests/test_update.bats`**

`test_update.bats` references the clone URL in a test assertion, not the footer. Straight rename.

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' tests/test_update.bats
./tests/bats/bin/bats tests/test_update.bats
```

Expected: green.

- [ ] **Step 8: Shellcheck notify.sh**

```bash
shellcheck scripts/lib/notify.sh
```

Expected: no warnings.

- [ ] **Step 9: Commit**

```bash
git add tests/test_notify.bats tests/test_update.bats \
        discord-bot/tests/test_embeds.py slack-bot/tests/test_blocks.py \
        scripts/lib/notify.sh discord-bot/bot.py slack-bot/bot.py \
        shared/dispatch_bot/__init__.py
git commit -m "chore(notify): rename footer and docstrings to sandbox-pal-action"
```

---

## Task 6: Rename in top-level project docs (excluding README tagline)

Catches the project-name references in CHANGELOG, CONTRIBUTING, SECURITY, and the issue-template config. README gets a mechanical rename in this task too, but the identity rewrites on the README (alt text + tagline) are handled separately in Task 7 for reviewability.

**Files:**
- Modify: `README.md` (URL/string rename only — tagline rewrite is Task 7)
- Modify: `CONTRIBUTING.md`
- Modify: `SECURITY.md`
- Modify: `.github/ISSUE_TEMPLATE/config.yml`

CHANGELOG is intentionally excluded here — it gets a new entry in Task 8 rather than a blind sweep, since the existing entry is a historical record of the prior `claude-agent-dispatch` → `claude-pal-action` rename and must stay worded as-is.

- [ ] **Step 1: Rename the project-name string**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  README.md \
  CONTRIBUTING.md \
  SECURITY.md \
  .github/ISSUE_TEMPLATE/config.yml
```

- [ ] **Step 2: Verify**

```bash
grep -n "claude-pal-action" README.md CONTRIBUTING.md SECURITY.md .github/ISSUE_TEMPLATE/config.yml
```

Expected: no output.

- [ ] **Step 3: Confirm the CHANGELOG historical line is unchanged**

```bash
grep -n "claude-agent-dispatch" CHANGELOG.md
```

Expected: one hit on line 11, with the full historical sentence intact. Confirms the sweep did not alter past-tense history.

- [ ] **Step 4: Commit**

```bash
git add README.md CONTRIBUTING.md SECURITY.md .github/ISSUE_TEMPLATE/config.yml
git commit -m "chore(docs): rename project-name refs in README, CONTRIBUTING, SECURITY"
```

---

## Task 7: Rewrite README identity surfaces (alt text + tagline)

The README image alt text and the tagline paragraph are outward-facing identity copy. They currently say "Claude Pal Action" and pitch the project as a Claude Code orchestration tool. These get rewritten to model-agnostic copy. Disclaimer, feature bullets, and deeper product references stay as-is (still accurate).

**Files:**
- Modify: `README.md:2` (alt attribute)
- Modify: `README.md:11` (tagline paragraph)

- [ ] **Step 1: Rewrite the image alt text**

Edit `README.md` line 2 from:
```html
  <img src=".github/icon.png" width="600" alt="Claude Pal Action">
```

to:
```html
  <img src=".github/icon.png" width="600" alt="Sandbox Pal Action">
```

- [ ] **Step 2: Rewrite the tagline paragraph**

Edit `README.md` line 11 from:
```
A reusable dispatch system for running [Claude Code](https://claude.com/claude-code) agents on GitHub issues — triaging, planning, implementing, and addressing PR review feedback, all orchestrated through GitHub Actions and a label-driven state machine.
```

to:
```
A reusable dispatch system for running AI coding agents on GitHub issues — triaging, planning, implementing, and addressing PR review feedback, all orchestrated through GitHub Actions and a label-driven state machine.
```

- [ ] **Step 3: Verify the disclaimer paragraph (line 13) still mentions Claude Code**

```bash
sed -n '13p' README.md
```

Expected: the disclaimer sentence beginning "Independent, community-built project." is intact, including the Anthropic trademark reference. That sentence is accurate today and stays.

- [ ] **Step 4: Verify feature-bullet references to "Claude Code CLI" etc. are also intact**

```bash
grep -cn "Claude Code" README.md
```

Expected: 3 or 4 (disclaimer + 2–3 feature bullets). If zero, the tagline edit was too aggressive — revisit.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "chore(readme): rewrite alt text and tagline to drop Claude brand name"
```

---

## Task 8: docs/ directory sweep

Ten Markdown files under `docs/` still carry `claude-pal-action` references — install URLs, `uses:` examples, narrative mentions of the project by name. Pure string rename.

**Files:**
- Modify: `docs/bot-account.md`
- Modify: `docs/configuration.md`
- Modify: `docs/customization.md`
- Modify: `docs/getting-started.md`
- Modify: `docs/notifications.md`
- Modify: `docs/operations.md`
- Modify: `docs/runners.md`
- Modify: `docs/versioning.md`
- Modify: `docs/issues/adversarial-prompts-need-json-only-reinforcement.md`
- Modify: `docs/issues/err-trap-double-report-on-controlled-failures.md`

- [ ] **Step 1: Rename**

```bash
sed -i 's/claude-pal-action/sandbox-pal-action/g' \
  docs/bot-account.md \
  docs/configuration.md \
  docs/customization.md \
  docs/getting-started.md \
  docs/notifications.md \
  docs/operations.md \
  docs/runners.md \
  docs/versioning.md \
  docs/issues/adversarial-prompts-need-json-only-reinforcement.md \
  docs/issues/err-trap-double-report-on-controlled-failures.md
```

- [ ] **Step 2: Verify**

```bash
grep -rn "claude-pal-action" docs/ --include="*.md" \
  | grep -v "^docs/superpowers/"
```

Expected: no output. Any hit outside `docs/superpowers/` is a miss.

- [ ] **Step 3: Confirm historical docs in `docs/superpowers/` are intentionally untouched**

```bash
grep -rln "claude-pal-action" docs/superpowers/plans/ docs/superpowers/specs/ | head
```

May return several files. Expected — these are historical and intentionally frozen.

- [ ] **Step 4: Commit**

```bash
git add docs/bot-account.md docs/configuration.md docs/customization.md \
        docs/getting-started.md docs/notifications.md docs/operations.md \
        docs/runners.md docs/versioning.md docs/issues/
git commit -m "chore(docs): rename project-name refs across docs/"
```

---

## Task 9: CHANGELOG entry

Add an Unreleased entry matching the prior rename's wording and reference this plan. The existing entry for the 2026-04-18 rename stays unchanged.

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a new bullet under the `### Changed` heading in `## [Unreleased]`**

Edit `CHANGELOG.md` to prepend a new bullet above the existing 2026-04-18 bullet, so the `### Changed` block reads:

```markdown
### Changed
- Repository renamed from `jnurre64/claude-pal-action` to `jnurre64/sandbox-pal-action` (2026-04-23). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. Motivated by upcoming multi-model support; dropping the "Claude" brand name from the project identity. See `docs/superpowers/plans/2026-04-23-rename-to-sandbox-pal-action.md`.
- Repository renamed from `jnurre64/claude-agent-dispatch` to `jnurre64/claude-pal-action` (2026-04-18). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. See `docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md`.
```

- [ ] **Step 2: Verify ordering (newest first) and spelling**

```bash
sed -n '8,14p' CHANGELOG.md
```

Expected: `## [Unreleased]` header, blank line, `### Changed`, new bullet first, old bullet second.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): record rename to sandbox-pal-action"
```

---

## Task 10: Whole-repo verification

Confirm the sweep is exhaustive, tests pass, and shellcheck is clean.

- [ ] **Step 1: Rerun the scope grep — expect zero hits outside historical paths**

```bash
grep -rln "claude-pal-action" \
  --include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" \
  --include="*.env*" --include="*.json" --include="*.py" --include="*.toml" \
  --include="*.bats" \
  . 2>/dev/null \
  | grep -v "^\./docs/superpowers/plans/\|^\./docs/superpowers/specs/\|^\./\.worktrees/\|^\./\.git/\|\.venv/"
```

Expected: no output. This is the headline success signal.

- [ ] **Step 2: Confirm historical paths still carry the old name (sanity check)**

```bash
grep -rln "claude-pal-action" docs/superpowers/ | head
```

Expected: at least one file in plans/ or specs/ (other than this plan, which uses the new name). Confirms the exclusion did its job and history is frozen.

- [ ] **Step 3: Shellcheck all shell scripts**

```bash
shellcheck scripts/*.sh scripts/lib/*.sh
```

Expected: zero warnings.

- [ ] **Step 4: Run the full BATS suite**

```bash
./tests/bats/bin/bats tests/
```

Expected: all tests pass. Pay attention to `test_notify.bats` and `test_update.bats` — those were touched directly.

- [ ] **Step 5: Run Python bot tests (if venvs are present)**

```bash
cd discord-bot && .venv/bin/python -m pytest tests/ -v && cd ..
cd slack-bot && .venv/bin/python -m pytest tests/ -v && cd ..
```

Expected: both green. If venvs are absent, note it in the PR description and rely on CI.

- [ ] **Step 6: Spot-check the final README renders cleanly**

```bash
head -25 README.md
```

Expected: new alt text `Sandbox Pal Action` on line 2; new tagline on line 11 starting "A reusable dispatch system for running AI coding agents…"; disclaimer on line 13 intact; feature bullets with "Claude Code CLI" intact.

- [ ] **Step 7: No commit (verification only)**

---

## Task 11: Push branch and open PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin chore/rename-to-sandbox-pal-action
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create \
  --title "chore: rename project from claude-pal-action to sandbox-pal-action" \
  --body "$(cat <<'EOF'
## Summary
- Rename every in-tree reference to `claude-pal-action` (35 files, ~60–90 occurrences) to `sandbox-pal-action`.
- Rewrite outward-facing identity surfaces: README image alt text, README tagline, notification footer strings.
- Leave "Claude Code" product/CLI references intact — the underlying agent is still Claude Code today; broader model-agnostic scrub is a separate effort.
- Historical plans/specs under `docs/superpowers/` intentionally untouched.
- No version bump — matches the 2026-04-18 rename precedent.

See `docs/superpowers/plans/2026-04-23-rename-to-sandbox-pal-action.md` for the full plan.

## Out of scope (post-merge follow-ups)
- GitHub repo rename in Settings (redirects then cover the old URL indefinitely).
- Update GitHub repo description to: "Reusable agent dispatch system — label-driven GitHub Actions workflows for issue triage, planning, implementation, and PR review."
- Update local git remote: `git remote set-url origin git@github.com-infra:jnurre64/sandbox-pal-action.git`.
- Update consumer repos: Webber (personal, on this machine, different PAT), `recipe-manager-demo`, `dodge-the-creeps-demo`.

## Test plan
- [ ] `shellcheck scripts/*.sh scripts/lib/*.sh` is clean
- [ ] `./tests/bats/bin/bats tests/` passes
- [ ] `pytest` in `discord-bot/` and `slack-bot/` passes (or CI covers)
- [ ] Final grep for `claude-pal-action` in non-historical paths returns empty

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Confirm the PR URL and CI status**

```bash
gh pr view --json url,statusCheckRollup | jq '{url, checks: (.statusCheckRollup | map({name, status, conclusion}))}'
```

Expected: PR URL printed; checks either pending or green.

---

## Post-merge follow-ups (not tasks — human-executed checklist)

Deliberately out of scope for this PR. Captured here so nothing drops.

1. **Rename the GitHub repo.** GitHub Settings → General → Rename → `sandbox-pal-action`. GitHub auto-installs permanent redirects for git URLs, issue/PR/commit links, release download URLs, and the API. Redirects hold until (and unless) someone creates a new repo at the old name — mitigation: leave the redirect stub in place, do not create anything at `jnurre64/claude-pal-action`.
2. **Update the GitHub repo description** to: *"Reusable agent dispatch system — label-driven GitHub Actions workflows for issue triage, planning, implementation, and PR review."* (`gh repo edit --description "..."` works too.)
3. **Update local git remote** on this machine:
   ```bash
   git remote set-url origin git@github.com-infra:jnurre64/sandbox-pal-action.git
   ```
4. **Update consumer repos** — their workflows reference `jnurre64/claude-pal-action/.github/workflows/...@v1`. GitHub redirects keep them working, but each should be migrated when next touched:
   - **Webber** (personal repo on this machine; uses a different PAT — handle separately, outside this PR). Highest priority: confirm Webber still runs end-to-end after the rename.
   - `recipe-manager-demo`
   - `dodge-the-creeps-demo`
5. **Verify CI badges** in the README render (shields.io may cache briefly; a hard refresh resolves it).
6. **Optional:** if any bot account display names include "claude-pal-action", rename those too.

---

## Self-review notes

- **Spec coverage:** every file in the inventory maps to exactly one task. Identity-surface rewrites (alt text, tagline, footer, repo description) are each called out and have concrete replacement copy — no TBD.
- **No placeholders:** concrete commands, concrete replacement text, no "TBD"/"implement later".
- **Type consistency:** the new footer string `Automated by sandbox-pal-action` is used identically in Task 5 steps for notify.sh, the two Python bots, and all three test files. The tagline replacement in Task 7 matches the repo description in the Proposed Identity Copy section.
- **Historical freeze:** grep filters consistently exclude `docs/superpowers/plans/` and `docs/superpowers/specs/` from sweeps and include them in a sanity check (Task 10, Step 2) to confirm they stayed frozen.
