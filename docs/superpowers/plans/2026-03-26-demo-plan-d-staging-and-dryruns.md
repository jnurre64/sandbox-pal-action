# Plan D: Issue Staging & Dry Runs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the agent on demo issues to generate authentic plans and PRs, pre-stage the lifecycle states for the "cooking show" demo flow, prepare fallback materials, create the setup speed run repo, and complete three dry runs before the April 2, 2026 presentation.

**Architecture:** This plan orchestrates the agent on two repos (recipe-manager-demo and dodge-the-creeps-demo), stages issues at specific lifecycle states, and prepares presentation fallbacks. Work happens on both Linux (agent infrastructure) and Windows (app verification, Slidev, dry runs).

**Tech Stack:** GitHub CLI (`gh`), GitHub Actions, Discord bot, agent-dispatch system, .NET 9 (for app verification), Godot (for game verification), Slidev (for presentation)

**Prerequisites:**
- Plan A completed (repos created, agent-dispatch configured, issues created, runner verified)
- Plan B completed (.NET recipe app MVP built and pushed)
- Plan C completed (Slidev deck and speaker notes built)
- Discord bot running on Linux machine (`agent-dispatch-bot` systemd service)
- Self-hosted runner online and registered for both repos

**Key context:**
- Bot account: `pennyworth-bot`
- Discord config: `~/agent-infra/config.env` — `AGENT_DISPATCH_REPO` must be updated per-repo when running the agent
- Recipe app repo: `Frightful-Games/recipe-manager-demo`
- Godot repo: `Frightful-Games/dodge-the-creeps-demo`
- Setup speed run repo: `Frightful-Games/recipe-manager-setup-demo`
- Presentation spec: `docs/superpowers/specs/2026-03-26-presentation-demo-design.md` (branch `presentation/demo-prep`)

**Important:** The Discord bot's `AGENT_DISPATCH_REPO` config controls which repo the bot interacts with. When staging issues across repos, update this value and restart the bot before running each repo's agent jobs.

---

## Pre-Staging Overview

The demo flow requires issues at specific lifecycle states. We achieve this by running the agent for real, then "freezing" issues at the right state:

| Issue | Feature | Target State | How to Stage |
|---|---|---|---|
| #1 Dark mode toggle | Recipe app | Fresh (no labels) | Don't run agent on it — leave it for live demo |
| #2 Recipe rating | Recipe app | `agent:plan-review` with plan | Run triage, stop after plan is posted |
| #3 Favorites | Recipe app | `agent:plan-review` with feedback + revised plan | Run triage, post feedback, let agent revise |
| #4 Search/filter | Recipe app | `agent:pr-open` with merged PR | Run full lifecycle: triage → approve → implement → PR |
| Godot power-up | Godot | `agent:pr-open` with merged PR | Run full lifecycle on Godot repo |

---

### Task 1: Stage "Add search/filter" — full lifecycle (recipe app)

This is the most time-consuming issue. Run it first so the agent has time to work.

**Files:**
- No files — operates through GitHub API and agent-dispatch

- [ ] **Step 1: Update Discord bot config to point at recipe app**

On the Linux machine, edit `~/agent-infra/config.env`:

```bash
# Change AGENT_DISPATCH_REPO to the recipe app
sed -i 's|AGENT_DISPATCH_REPO=.*|AGENT_DISPATCH_REPO="Frightful-Games/recipe-manager-demo"|' ~/agent-infra/config.env
systemctl --user restart agent-dispatch-bot
```

Verify:
```bash
journalctl --user -u agent-dispatch-bot --since "30 seconds ago" --no-pager
```

- [ ] **Step 2: Trigger triage on issue #4 (search/filter)**

```bash
gh issue edit 4 --repo Frightful-Games/recipe-manager-demo --add-label "agent"
```

Monitor: Check GitHub Actions tab for the triage workflow to start. Wait for it to complete — the agent will post a plan comment and add the `agent:plan-review` label.

- [ ] **Step 3: Approve the plan**

Once the plan is posted, approve it either via Discord (click Approve button) or via CLI:

```bash
gh issue edit 4 --repo Frightful-Games/recipe-manager-demo --remove-label "agent:plan-review" --add-label "agent:plan-approved"
gh api repos/Frightful-Games/recipe-manager-demo/dispatches \
  -f event_type=agent-implement \
  -f 'client_payload[issue_number]=4'
```

- [ ] **Step 4: Wait for implementation to complete**

Monitor the implement workflow in GitHub Actions. The agent will:
- Write code following TDD
- Run `dotnet test`
- Create a PR

This may take 10-30 minutes depending on complexity.

- [ ] **Step 5: Review and merge the PR**

Once the PR is created:
- Review the code — it should add search/filter functionality
- If the code looks reasonable, merge the PR
- Pull the changes to your local Windows machine to verify the feature works

```bash
gh pr merge --repo Frightful-Games/recipe-manager-demo --squash
```

- [ ] **Step 6: Verify the feature works locally (Windows)**

On Windows:
```bash
cd ~/repos/recipe-manager-demo
git pull
rm -f RecipeManager/recipes.db
dotnet run --project RecipeManager
```

Visit the app — search/filter should work on the recipes page. This is what you'll show in the demo.

---

### Task 2: Stage "Add recipe rating" — plan review state

**Files:**
- No files — operates through GitHub API

- [ ] **Step 1: Trigger triage on issue #2 (recipe rating)**

```bash
gh issue edit 2 --repo Frightful-Games/recipe-manager-demo --add-label "agent"
```

- [ ] **Step 2: Wait for triage to complete**

Monitor GitHub Actions. The agent will post a plan comment and add `agent:plan-review`.

- [ ] **Step 3: STOP — do not approve**

The issue should now be at `agent:plan-review` with a detailed plan comment. This is the target state. The Discord notification for this issue should still have active Approve/Request Changes/Comment buttons.

- [ ] **Step 4: Verify the plan looks good for demo**

Read the plan comment on the issue. It should describe:
- Adding a Rating property to the model
- Updating the UI with star display
- Database migration

If the plan is unclear or poorly written, you may need to reset and re-triage:
```bash
gh issue edit 2 --repo Frightful-Games/recipe-manager-demo --remove-label "agent:plan-review" --add-label "agent"
```

---

### Task 3: Stage "Add favorites" — feedback loop state

**Files:**
- No files — operates through GitHub API

- [ ] **Step 1: Trigger triage on issue #3 (favorites)**

```bash
gh issue edit 3 --repo Frightful-Games/recipe-manager-demo --add-label "agent"
```

- [ ] **Step 2: Wait for triage to complete**

Monitor GitHub Actions. The agent will post a plan and add `agent:plan-review`.

- [ ] **Step 3: Post feedback via Discord (or CLI)**

Click "Request Changes" in Discord and type feedback like:
> "Please use a heart icon (❤️) for the favorites toggle instead of a generic button. Also, add the favorites filter as a toggle on the existing recipes page rather than a separate page."

Or via CLI:
```bash
gh issue comment 3 --repo Frightful-Games/recipe-manager-demo --body "Please use a heart icon (❤️) for the favorites toggle instead of a generic button. Also, add the favorites filter as a toggle on the existing recipes page rather than a separate page."
```

- [ ] **Step 4: Let the agent revise the plan**

After posting feedback, the reply workflow should trigger (either via the Discord bot dispatch or via the `issue_comment` event). The agent will read the feedback and post a revised plan.

If the reply workflow doesn't trigger automatically (because the comment was from `pennyworth-bot` and the actor guard blocks it), trigger it manually:

```bash
gh api repos/Frightful-Games/recipe-manager-demo/dispatches \
  -f event_type=agent-reply \
  -f 'client_payload[issue_number]=3'
```

- [ ] **Step 5: STOP after the revised plan is posted**

The issue should now have:
1. Original plan comment
2. Your feedback comment
3. Revised plan comment from the agent

This shows the full feedback loop in the demo. Don't approve — leave it at `agent:plan-review`.

---

### Task 4: Stage the Godot power-up — full lifecycle

**Files:**
- No files — operates through GitHub API

- [ ] **Step 1: Update Discord bot config to point at Godot repo**

```bash
sed -i 's|AGENT_DISPATCH_REPO=.*|AGENT_DISPATCH_REPO="Frightful-Games/dodge-the-creeps-demo"|' ~/agent-infra/config.env
systemctl --user restart agent-dispatch-bot
```

- [ ] **Step 2: Trigger triage**

```bash
gh issue edit 1 --repo Frightful-Games/dodge-the-creeps-demo --add-label "agent"
```

- [ ] **Step 3: Wait for plan, then approve**

Once the plan is posted, approve:

```bash
gh issue edit 1 --repo Frightful-Games/dodge-the-creeps-demo --remove-label "agent:plan-review" --add-label "agent:plan-approved"
gh api repos/Frightful-Games/dodge-the-creeps-demo/dispatches \
  -f event_type=agent-implement \
  -f 'client_payload[issue_number]=1'
```

- [ ] **Step 4: Wait for implementation and merge**

```bash
gh pr merge --repo Frightful-Games/dodge-the-creeps-demo --squash
```

- [ ] **Step 5: Verify the game works (Windows)**

On Windows, pull the changes and open in Godot editor:
- Run the original game (checkout the commit before the agent's changes) — record/screenshot the "before"
- Run the modified game — verify the power-up spawns and works — record/screenshot the "after"

The visual difference is the payoff for the Godot cameo in the demo.

---

### Task 5: Reset Discord bot config for presentation

**Files:**
- Modify: `~/agent-infra/config.env`

- [ ] **Step 1: Point Discord bot back at recipe app for the demo**

```bash
sed -i 's|AGENT_DISPATCH_REPO=.*|AGENT_DISPATCH_REPO="Frightful-Games/recipe-manager-demo"|' ~/agent-infra/config.env
systemctl --user restart agent-dispatch-bot
```

The live demo uses the recipe app, so the bot should be configured for that repo.

---

### Task 6: Prepare the setup speed run repo

**Files:**
- Populate: `Frightful-Games/recipe-manager-setup-demo`

- [ ] **Step 1: Clone the recipe app and strip agent-dispatch**

```bash
cd ~/repos
git clone https://github.com/Frightful-Games/recipe-manager-demo.git recipe-manager-setup-demo-temp
cd recipe-manager-setup-demo-temp

# Remove agent-dispatch config
rm -rf .agent-dispatch
rm -rf .github/workflows/agent-*.yml
rm -f labels.txt

# Commit to a clean state
git add -A
git commit -m "chore: remove agent-dispatch config for setup demo"
```

- [ ] **Step 2: Push to the setup demo repo**

```bash
git remote set-url origin https://github.com/Frightful-Games/recipe-manager-setup-demo.git
git push -u origin main --force
```

- [ ] **Step 3: Verify**

```bash
gh repo view Frightful-Games/recipe-manager-setup-demo --web
```

The repo should have the .NET app code but no `.agent-dispatch/` directory and no `agent-*.yml` workflows. This is the clean starting point for the `/setup` speed run.

---

### Task 7: Prepare fallback materials

**Files:**
- Screenshots and optionally a screen recording

- [ ] **Step 1: Take screenshots of each demo stage**

From Windows, capture screenshots of:
1. The recipe app running in the browser (recipe list page with seed data)
2. A fresh issue in GitHub (dark mode toggle, no labels)
3. A GitHub Actions workflow running (triage in progress)
4. A Discord notification with action buttons
5. A plan comment on an issue (recipe rating plan)
6. A Discord approval confirmation
7. A feedback comment + revised plan (favorites issue)
8. A completed PR (search/filter PR diff view)
9. The search/filter feature working in the app
10. The Godot game before and after the power-up
11. The `/setup` skill running

Save these in `~/presentation/public/fallback/` so they're accessible as backup slides.

- [ ] **Step 2: (Optional) Record a demo walkthrough**

During Dry Run 2, record a screen recording of the full demo flow (3-5 minutes, sped up). Save as `~/presentation/public/fallback/demo-recording.mp4`. This is the nuclear fallback — if everything goes wrong, play this.

---

### Task 8: Dry Run 1 — Technical Verification (Saturday)

- [ ] **Step 1: Verify all pre-staged issues are correct**

```bash
# Check issue states
gh issue list --repo Frightful-Games/recipe-manager-demo --json number,title,labels --jq '.[] | "\(.number): \(.title) [\(.labels | map(.name) | join(", "))]"'
```

Expected:
- #1 Dark mode toggle — no labels
- #2 Recipe rating — `agent:plan-review`
- #3 Favorites — `agent:plan-review` (with feedback comments)
- #4 Search/filter — closed (PR merged)

- [ ] **Step 2: Verify the recipe app runs with search/filter**

On Windows:
```bash
cd ~/repos/recipe-manager-demo
git pull
rm -f RecipeManager/recipes.db
dotnet run --project RecipeManager
```

- Click through all CRUD operations
- Verify search/filter works
- Verify the app looks good on screenshare (font size, contrast)

- [ ] **Step 3: Verify Discord bot is working**

Check that the Discord notifications for issues #2 and #3 still have active buttons. Click nothing — just verify they're there.

- [ ] **Step 4: Verify GitHub Actions can trigger**

Test a dispatch event:
```bash
gh api repos/Frightful-Games/recipe-manager-demo/dispatches \
  -f event_type=agent-implement \
  -f 'client_payload[issue_number]=2'
```

Check that a workflow run appears in the Actions tab. Cancel it immediately — we don't want it to actually run.

- [ ] **Step 5: Verify the Godot game works**

Open the Godot project, run the game, verify the power-up feature works. Also open the original version (before agent changes) to verify you can show the "before" state.

- [ ] **Step 6: Verify Slidev presentation**

```bash
cd ~/presentation
npm run dev
```

Click through all slides. Enter presenter mode. Verify Mermaid diagrams render and speaker notes are visible.

- [ ] **Step 7: Verify the setup speed run repo**

```bash
cd ~/repos/recipe-manager-setup-demo
claude
# Type: /setup
# Answer 2-3 prompts, then exit
```

Verify the skill starts and asks the right questions.

- [ ] **Step 8: Time the full flow**

Walk through the entire demo sequence (steps 1-20 from the spec) with a stopwatch. Note:
- Which segments run long
- Where transitions feel awkward
- Any technical glitches

---

### Task 9: Dry Run 2 — Full Rehearsal (Sunday)

- [ ] **Step 1: Set up the presentation environment**

On Windows, arrange your screen:
- Slidev in one browser tab
- Recipe app in another tab
- GitHub repo in another tab
- Discord in a separate window (or tab)
- Terminal ready for the setup speed run

- [ ] **Step 2: Present the full talk out loud with timer**

Start a timer. Present from slide 1 through the full demo, Godot cameo, setup speed run, and closing slides. Talk out loud — don't just click through silently.

**Time checkpoints:**
- End of slides, start demo: 8:00
- Finish main demo: 20:00
- Finish Godot cameo: 22:00
- Finish setup speed run: 24:00
- Start Q&A: 25:00

- [ ] **Step 3: Note adjustments**

After the rehearsal, note:
- Total time
- Which segments ran long/short
- Transitions that felt awkward
- Any content that didn't land well when said out loud
- Technical issues

- [ ] **Step 4: (Optional) Record this rehearsal**

Record your screen during the rehearsal. This serves as both:
- A review tool (watch yourself, find improvement areas)
- The fallback demo recording

---

### Task 10: Dry Run 3 — Final Check (Wednesday morning, 1 hour before)

- [ ] **Step 1: Restart the Discord bot**

```bash
systemctl --user restart agent-dispatch-bot
journalctl --user -u agent-dispatch-bot --since "30 seconds ago" --no-pager
```

Verify: Connected to Discord gateway.

- [ ] **Step 2: Verify no other agent jobs are running**

```bash
gh run list --repo Frightful-Games/recipe-manager-demo --status in_progress
gh run list --repo Frightful-Games/dodge-the-creeps-demo --status in_progress
```

Expected: No in-progress runs.

- [ ] **Step 3: Open all browser tabs in order**

1. Slidev (`http://localhost:3030`)
2. Recipe app running (`https://localhost:5001/Recipes`)
3. GitHub: recipe-manager-demo issues tab
4. GitHub: issue #1 (dark mode — for live labeling)
5. GitHub: issue #2 (recipe rating — pre-staged plan)
6. GitHub: issue #3 (favorites — pre-staged feedback)
7. GitHub: search/filter PR (merged)
8. GitHub: dodge-the-creeps-demo PR (merged)
9. Discord channel
10. Terminal (for setup speed run)

- [ ] **Step 4: Test the dispatch path**

```bash
gh api repos/Frightful-Games/recipe-manager-demo/dispatches \
  -f event_type=agent-triage \
  -f 'client_payload[issue_number]=1'
```

Verify a workflow appears in Actions. Cancel it immediately.

- [ ] **Step 5: Test screenshare**

Join the actual meeting platform early. Share your screen. Verify:
- Slidev is readable (font size)
- Recipe app is readable
- GitHub text is readable
- Discord is readable
- Terminal text is readable

Increase font sizes if needed.

- [ ] **Step 6: You're ready. Take a breath. Present.**
