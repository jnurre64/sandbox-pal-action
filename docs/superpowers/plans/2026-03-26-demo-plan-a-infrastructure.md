# Plan A: Infrastructure & Repo Setup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create and configure three GitHub demo repos for a presentation on April 2, 2026: a .NET recipe app (primary demo), a Godot dodge_the_creeps fork (secondary demo), and a setup speed run repo.

**Architecture:** All three repos live under the `jnurre64` GitHub account. The .NET and Godot repos get full agent-dispatch standalone configuration with Discord bot integration. The setup speed run repo is a bare clone with no agent-dispatch config (used to demo the `/setup` skill). All repos use the `pennyworth-bot` bot account.

**Tech Stack:** GitHub CLI (`gh`), Git, YAML (GitHub Actions workflows), shell (agent-dispatch config)

**Machine:** Linux (SSH) — `~/claude-agent-dispatch/` is the dispatch repo. Self-hosted runner is on this machine. Discord bot (`agent-dispatch-bot` systemd service) runs here.

**Key context:**
- Bot account: `pennyworth-bot`
- Bot PAT: stored as `GITHUB_TOKEN` env var on this machine and in `~/agent-infra/config.env` as `GH_TOKEN`
- Discord bot config: `~/agent-infra/config.env` (shared across projects — `AGENT_DISPATCH_REPO` will need to be updated per-repo during staging)
- Agent-dispatch repo: `~/claude-agent-dispatch/` (branch `presentation/demo-prep`)
- Standalone templates: `~/claude-agent-dispatch/.claude/skills/setup/templates/standalone/`
- The presentation spec is at: `docs/superpowers/specs/2026-03-26-presentation-demo-design.md`

---

## File Structure

Each demo repo needs these agent-dispatch files in standalone mode:

```
<repo>/
├── .agent-dispatch/
│   ├── scripts/          # Copied from ~/claude-agent-dispatch/scripts/
│   ├── prompts/          # Copied from ~/claude-agent-dispatch/prompts/
│   ├── config.env        # Project-specific config
│   └── .upstream         # Version tracking
├── .github/
│   └── workflows/
│       ├── agent-triage.yml
│       ├── agent-implement.yml
│       ├── agent-reply.yml
│       ├── agent-review.yml
│       ├── agent-dispatch.yml   # Discord bot dispatch
│       └── agent-cleanup.yml
├── CLAUDE.md             # Project instructions for Claude
└── labels.txt            # Agent labels for batch creation
```

---

### Task 1: Create the .NET recipe app repo on GitHub

**Files:**
- No local files yet — this creates the remote repo

- [ ] **Step 1: Create the repo**

```bash
gh repo create jnurre64/recipe-manager-demo --public --description "Demo .NET recipe manager for Claude Agent Dispatch presentation" --clone
```

- [ ] **Step 2: Initialize with a README and .gitignore**

```bash
cd ~/repos/recipe-manager-demo
echo "# Recipe Manager Demo" > README.md
echo "A .NET 8 recipe manager used to demonstrate Claude Agent Dispatch." >> README.md
echo "" >> README.md
echo "> This is a demo project for a presentation. Not intended for production use." >> README.md
curl -sL https://raw.githubusercontent.com/github/gitignore/main/VisualStudio.gitignore > .gitignore
git add README.md .gitignore
git commit -m "Initial commit"
git push -u origin main
```

- [ ] **Step 3: Add the AGENT_PAT secret**

```bash
gh secret set AGENT_PAT --repo jnurre64/recipe-manager-demo
```

When prompted, paste the `pennyworth-bot` fine-grained PAT.

- [ ] **Step 4: Commit**

Already committed in step 2.

---

### Task 2: Configure agent-dispatch on the recipe app repo (standalone mode)

**Files:**
- Create: `~/repos/recipe-manager-demo/.agent-dispatch/` (entire directory)
- Create: `~/repos/recipe-manager-demo/.github/workflows/agent-*.yml` (6 workflow files)
- Create: `~/repos/recipe-manager-demo/CLAUDE.md`
- Create: `~/repos/recipe-manager-demo/labels.txt`

- [ ] **Step 1: Run the /setup skill interactively**

The easiest way to configure agent-dispatch is to use Claude with the `/setup` skill. From the recipe-manager-demo directory:

```bash
cd ~/repos/recipe-manager-demo
claude
# Then type: /setup
```

When prompted:
- **Mode:** Standalone
- **Bot username:** `pennyworth-bot`
- **Target repo:** current directory (~/repos/recipe-manager-demo)
- **Config values:**
  - `AGENT_BOT_USER=pennyworth-bot`
  - `AGENT_TEST_COMMAND=dotnet test` (will be used once the .NET app has tests)
  - `AGENT_EXTRA_TOOLS=Bash(dotnet:*)`
  - `AGENT_NOTIFY_BACKEND=bot`

Alternatively, if `/setup` is not available or you prefer manual setup, follow steps 2-5 below.

- [ ] **Step 2: Copy agent-dispatch scripts and prompts**

```bash
cd ~/repos/recipe-manager-demo
mkdir -p .agent-dispatch
cp -r ~/claude-agent-dispatch/scripts .agent-dispatch/
cp -r ~/claude-agent-dispatch/prompts .agent-dispatch/
cp ~/claude-agent-dispatch/labels.txt .
```

- [ ] **Step 3: Create the project config.env**

Create `.agent-dispatch/config.env`:

```bash
cat > .agent-dispatch/config.env << 'EOF'
AGENT_BOT_USER="pennyworth-bot"
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_CIRCUIT_BREAKER_LIMIT=8
AGENT_TEST_COMMAND="dotnet test"
AGENT_EXTRA_TOOLS="Bash(dotnet:*)"
AGENT_NOTIFY_BACKEND="bot"
EOF
```

- [ ] **Step 4: Generate workflow files from standalone templates**

For each template in `~/claude-agent-dispatch/.claude/skills/setup/templates/standalone/`, copy it to `.github/workflows/` and replace `{{BOT_USER}}` with `pennyworth-bot`:

```bash
mkdir -p .github/workflows
for template in ~/claude-agent-dispatch/.claude/skills/setup/templates/standalone/agent-*.yml; do
    filename=$(basename "$template")
    sed 's/{{BOT_USER}}/pennyworth-bot/g' "$template" > ".github/workflows/$filename"
done
```

- [ ] **Step 5: Create CLAUDE.md**

Create `CLAUDE.md` at the repo root:

```markdown
# Recipe Manager Demo

A .NET 8 Razor Pages recipe manager application.

## Tech Stack
- .NET 8, Razor Pages, Entity Framework Core, SQLite

## Development
- Run: `dotnet run`
- Test: `dotnet test`
- Build: `dotnet build`

## Project Structure
- `Models/` — Data models (Recipe)
- `Pages/` — Razor Pages (CRUD)
- `Data/` — EF Core DbContext and seed data
```

- [ ] **Step 6: Create labels on the repo**

```bash
cd ~/repos/recipe-manager-demo
while IFS= read -r line; do
    name=$(echo "$line" | cut -d'|' -f1 | xargs)
    color=$(echo "$line" | cut -d'|' -f2 | xargs)
    desc=$(echo "$line" | cut -d'|' -f3 | xargs)
    gh label create "$name" --color "$color" --description "$desc" --repo jnurre64/recipe-manager-demo 2>/dev/null || true
done < labels.txt
```

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "feat: add agent-dispatch standalone config"
git push
```

---

### Task 3: Create demo issues on the recipe app repo

**Files:**
- No files — creates GitHub issues via CLI

- [ ] **Step 1: Create "Add dark mode toggle" issue**

```bash
gh issue create --repo jnurre64/recipe-manager-demo \
  --title "Add dark mode toggle" \
  --body "$(cat <<'EOF'
Add a dark mode toggle to the recipe manager application.

## Requirements
- Add a toggle button/switch in the navigation bar
- Clicking the toggle switches between light and dark themes
- Store the user's preference in localStorage so it persists across page loads
- Dark mode should apply to all pages consistently
- Use CSS custom properties (variables) for theme colors so the switch is clean
EOF
)"
```

- [ ] **Step 2: Create "Add recipe rating" issue**

```bash
gh issue create --repo jnurre64/recipe-manager-demo \
  --title "Add recipe rating system" \
  --body "$(cat <<'EOF'
Add a 1-5 star rating system for recipes.

## Requirements
- Add a Rating property (integer, 1-5) to the Recipe model
- Display star ratings on the recipe list page and detail page
- Allow users to set/update the rating on the recipe detail page
- Show the average rating if we ever support multiple users (for now, just one rating per recipe)
- Use filled/empty star icons (Unicode stars ★☆ are fine)
- Update the database migration
EOF
)"
```

- [ ] **Step 3: Create "Add favorites" issue**

```bash
gh issue create --repo jnurre64/recipe-manager-demo \
  --title "Add favorites system" \
  --body "$(cat <<'EOF'
Add the ability to mark recipes as favorites.

## Requirements
- Add an IsFavorite boolean property to the Recipe model
- Add a heart icon on each recipe card/row that toggles favorite status
- Add a "Favorites" filter or separate page that shows only favorited recipes
- Favorite status should persist (saved to database)
- Use a heart icon (filled for favorited, outline for not)
- Update the database migration
EOF
)"
```

- [ ] **Step 4: Create "Add search/filter" issue**

```bash
gh issue create --repo jnurre64/recipe-manager-demo \
  --title "Add search and filter functionality" \
  --body "$(cat <<'EOF'
Add search and filtering to the recipe list page.

## Requirements
- Add a search bar at the top of the recipe list page
- Search should filter recipes by name and description (case-insensitive)
- Filter results update as the user types (or on form submit)
- Show a "No recipes found" message when search returns no results
- Preserve the search query in the URL so it survives page refresh
- Keep it server-side (query parameter, not JavaScript filtering)
EOF
)"
```

- [ ] **Step 5: Verify all issues created**

```bash
gh issue list --repo jnurre64/recipe-manager-demo
```

Expected: 4 open issues, no labels.

---

### Task 4: Fork Godot dodge_the_creeps

**Files:**
- No local files initially — fork and clone

- [ ] **Step 1: Fork the Godot demo projects repo**

```bash
gh repo fork godotengine/godot-demo-projects --clone --fork-name dodge-the-creeps-demo --org jnurre64
```

Note: If `--org` doesn't work with a personal account, fork manually via the GitHub UI or:

```bash
gh repo create jnurre64/dodge-the-creeps-demo --public --description "Godot dodge_the_creeps demo for Claude Agent Dispatch presentation"
cd ~/repos/dodge-the-creeps-demo
git clone https://github.com/godotengine/godot-demo-projects.git temp-clone
cp -r temp-clone/2d/dodge_the_creeps/* .
cp temp-clone/LICENSE.md .
rm -rf temp-clone
git add -A
git commit -m "Initial commit: dodge_the_creeps from Godot demo projects (MIT)"
git push -u origin main
```

- [ ] **Step 2: Add the AGENT_PAT secret**

```bash
gh secret set AGENT_PAT --repo jnurre64/dodge-the-creeps-demo
```

- [ ] **Step 3: Commit**

Already committed in step 1.

---

### Task 5: Configure agent-dispatch on the Godot repo (standalone mode)

**Files:**
- Create: `~/repos/dodge-the-creeps-demo/.agent-dispatch/` (entire directory)
- Create: `~/repos/dodge-the-creeps-demo/.github/workflows/agent-*.yml`
- Create: `~/repos/dodge-the-creeps-demo/CLAUDE.md`
- Create: `~/repos/dodge-the-creeps-demo/labels.txt`

- [ ] **Step 1: Copy agent-dispatch scripts and prompts**

```bash
cd ~/repos/dodge-the-creeps-demo
mkdir -p .agent-dispatch
cp -r ~/claude-agent-dispatch/scripts .agent-dispatch/
cp -r ~/claude-agent-dispatch/prompts .agent-dispatch/
cp ~/claude-agent-dispatch/labels.txt .
```

- [ ] **Step 2: Create the project config.env**

Create `.agent-dispatch/config.env`:

```bash
cat > .agent-dispatch/config.env << 'EOF'
AGENT_BOT_USER="pennyworth-bot"
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_CIRCUIT_BREAKER_LIMIT=8
AGENT_EXTRA_TOOLS="Bash(godot:*),Bash(Godot:*)"
AGENT_NOTIFY_BACKEND="bot"
EOF
```

- [ ] **Step 3: Generate workflow files from standalone templates**

```bash
mkdir -p .github/workflows
for template in ~/claude-agent-dispatch/.claude/skills/setup/templates/standalone/agent-*.yml; do
    filename=$(basename "$template")
    sed 's/{{BOT_USER}}/pennyworth-bot/g' "$template" > ".github/workflows/$filename"
done
```

- [ ] **Step 4: Create CLAUDE.md**

Create `CLAUDE.md` at the repo root:

```markdown
# Dodge the Creeps

A simple Godot 4 game where the player dodges enemies. Based on the official Godot "Your First 2D Game" tutorial.

## Tech Stack
- Godot 4, GDScript

## Project Structure
- `main.gd` — Main game scene logic (spawn mobs, manage score)
- `player.gd` — Player movement and hit detection
- `mob.gd` — Enemy mob behavior
- `hud.gd` — HUD display (score, start button, messages)

## Running
Open `project.godot` in the Godot editor and press F5 to run.
```

- [ ] **Step 5: Create labels on the repo**

```bash
while IFS= read -r line; do
    name=$(echo "$line" | cut -d'|' -f1 | xargs)
    color=$(echo "$line" | cut -d'|' -f2 | xargs)
    desc=$(echo "$line" | cut -d'|' -f3 | xargs)
    gh label create "$name" --color "$color" --description "$desc" --repo jnurre64/dodge-the-creeps-demo 2>/dev/null || true
done < labels.txt
```

- [ ] **Step 6: Create a demo issue for the Godot cameo**

```bash
gh issue create --repo jnurre64/dodge-the-creeps-demo \
  --title "Add power-up that grants temporary invincibility" \
  --body "$(cat <<'EOF'
Add a power-up item that spawns periodically and grants the player temporary invincibility.

## Requirements
- Create a new PowerUp scene (Area2D with a sprite and collision shape)
- Power-up spawns at a random position every 15-20 seconds
- When the player touches it, they become invincible for 3 seconds
- During invincibility, the player sprite should flash/glow to indicate the effect
- Mobs that touch an invincible player are destroyed instead of ending the game
- Power-up disappears after 5 seconds if not collected
- Add a visual indicator (timer bar or flashing) showing remaining invincibility time
EOF
)"
```

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "feat: add agent-dispatch standalone config"
git push
```

---

### Task 6: Create the setup speed run repo

**Files:**
- Creates a bare repo with the .NET recipe app code but no agent-dispatch config

- [ ] **Step 1: Create the repo**

```bash
gh repo create jnurre64/recipe-manager-setup-demo --public --description "Clean repo for demonstrating /setup skill in presentation"
```

- [ ] **Step 2: This repo will be populated later**

After Plan B completes (the .NET app is built), we'll clone the recipe-manager-demo repo, strip out `.agent-dispatch/`, `.github/workflows/agent-*`, and `labels.txt`, and push to this repo.

For now, just create the empty repo so it's ready.

- [ ] **Step 3: Commit**

No commit needed yet — repo is empty placeholder.

---

### Task 7: Verify self-hosted runner can reach both repos

**Files:**
- No files — verification only

- [ ] **Step 1: Check the runner is registered for both repos**

The self-hosted runner needs to be registered for `jnurre64/recipe-manager-demo` and `jnurre64/dodge-the-creeps-demo`. Check:

```bash
gh api repos/jnurre64/recipe-manager-demo/actions/runners --jq '.runners[].name'
gh api repos/jnurre64/dodge-the-creeps-demo/actions/runners --jq '.runners[].name'
```

If the runner is registered at the org/user level, it should appear for both. If not, register it for each repo via GitHub Settings > Actions > Runners.

- [ ] **Step 2: Verify the runner has the `agent` label**

The workflows use `runs-on: [self-hosted, agent]`. Verify:

```bash
gh api repos/jnurre64/recipe-manager-demo/actions/runners --jq '.runners[].labels[].name'
```

Should include both `self-hosted` and `agent`.

- [ ] **Step 3: Test a workflow trigger**

Create a simple test workflow or manually trigger one of the agent workflows to verify the runner picks it up:

```bash
gh api repos/jnurre64/recipe-manager-demo/dispatches \
  -f event_type=agent-triage \
  -f 'client_payload[issue_number]=1'
```

Check GitHub Actions tab — workflow should start (it will fail because the .NET app isn't built yet, but the runner picking it up confirms connectivity).
