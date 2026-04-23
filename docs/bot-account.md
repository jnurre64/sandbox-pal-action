# Bot Account Setup

This guide covers creating and configuring a dedicated GitHub account for the sandbox-pal-action agent, including PAT creation, permissions, and rotation.

---

## Why Use a Dedicated Bot Account

Using a personal GitHub account for the agent is possible but not recommended. A dedicated bot account provides:

- **Audit trail** -- Every comment, commit, push, and PR clearly comes from the bot. Reviewing activity is straightforward because the bot's profile page shows exactly what it has done.
- **Actor filter** -- The dispatch workflows use `github.actor != 'bot-username'` to prevent the bot's own actions from re-triggering workflows. If you use your personal account, your manual actions on issues would also be filtered out.
- **Permission isolation** -- The bot's PAT has only the scopes it needs. If the token is compromised, the blast radius is limited to the specific repositories and permissions you granted -- not your personal account's full access.
- **No interference** -- The bot's `gh` and `git` credentials on the runner do not conflict with your personal credentials. You can SSH into the runner and work alongside the bot without credential confusion.

---

## Step 1: Create a New GitHub Account

1. Open a private/incognito browser window (so you are not logged into your personal account)
2. Go to [github.com/signup](https://github.com/signup)
3. Create the account with:
   - A descriptive username (e.g., `myproject-bot`, `acme-ci-bot`, `your-name-bot`)
   - A dedicated email address (a `+` alias works: `you+bot@gmail.com`)
   - A strong, unique password stored in a password manager
4. Verify the email address
5. Skip the onboarding questions

**Tip:** Choose a username that makes it obvious this is a bot account. This helps collaborators understand why they see automated comments and PRs.

---

## Step 2: Configure the Account

### Profile

1. Go to **Settings > Profile**
2. Set the **Name** to something descriptive (e.g., "Acme CI Bot" or "Claude Agent")
3. Optionally set a **Bio** (e.g., "Automated agent for issue triage and implementation. Powered by Claude Code.")
4. Consider uploading an **avatar** that visually distinguishes the bot from human users. A robot icon, a project mascot, or a colored geometric shape all work well.

### Email settings

1. Go to **Settings > Emails**
2. Enable **Keep my email addresses private** -- the bot does not need a public email
3. The `noreply` address (e.g., `12345678+myproject-bot@users.noreply.github.com`) will be used for git commits

---

## Step 3: Create a Fine-Grained PAT

Fine-grained PATs are recommended over classic PATs because they can be scoped to specific repositories and permissions.

1. While logged in as the bot account, go to **Settings > Developer settings > Personal access tokens > Fine-grained tokens**
2. Click **Generate new token**
3. Fill in:
   - **Token name**: Something descriptive (e.g., `sandbox-pal-dispatch-pat`)
   - **Expiration**: Up to 1 year (set a calendar reminder 2 weeks before expiry)
   - **Resource owner**: The organization or user that owns the target repo. If the target repo is in an org, the org admin may need to approve the token request.
4. **Repository access**: Select **Only select repositories** and choose the target repo(s). Use "All repositories" only if the bot will work across many repos.
5. **Permissions** -- grant exactly these:

### Required permissions

| Permission | Access | Why |
|------------|--------|-----|
| **Contents** | Read and write | Clone the repo, read files, push branches |
| **Issues** | Read and write | Read issue bodies, post comments, manage labels |
| **Pull requests** | Read and write | Create PRs, read reviews, post review responses |
| **Metadata** | Read-only | Automatically included; basic repo information |

### Optional permissions

| Permission | Access | Why | When needed |
|------------|--------|-----|-------------|
| **Workflows** | Read and write | Trigger `workflow_dispatch` events | Only if the bot needs to trigger other workflows (e.g., deployment pipelines). Most setups do not need this. |

6. Click **Generate token**
7. **Copy the token immediately** -- GitHub will not show it again

Store the token in a password manager. You will need it in multiple places:
- As the `AGENT_PAT` secret in the target repo
- In the runner's `gh` authentication
- In the runner's `~/.git-credentials`

---

## Step 4: Add the Bot as a Collaborator

The bot needs write access to the target repo.

### Via GitHub CLI (from your personal account)

```bash
gh api repos/OWNER/REPO/collaborators/BOT_USERNAME \
  -X PUT -f permission=write
```

### Via the GitHub web UI

1. Go to the target repo's **Settings > Collaborators**
2. Click **Add people**
3. Search for the bot's username
4. Select **Write** access
5. Click **Add**

### Accept the invitation

Log in as the bot account and accept the collaboration invitation. You can find it at [github.com/notifications](https://github.com/notifications) or in the bot's email.

---

## Step 5: Set the PAT as a GitHub Actions Secret

The target repo's workflows need the bot's PAT to authenticate.

### AGENT_PAT (required)

```bash
# Run this authenticated as a repo admin (your personal account, not the bot)
gh secret set AGENT_PAT --repo OWNER/REPO
# Paste the fine-grained PAT when prompted
```

Or through the web UI: **Settings > Secrets and variables > Actions > New repository secret**. Name it `AGENT_PAT` and paste the token.

### AGENT_GIST_PAT (optional)

The cleanup workflow can delete orphaned gists created during agent runs. Fine-grained PATs do not support gist permissions, so this requires a **classic** PAT.

To create one:

1. Log in as the bot account
2. Go to **Settings > Developer settings > Personal access tokens > Tokens (classic)**
3. Click **Generate new token**
4. Grant only the **`gist`** scope
5. Set expiration (classic PATs can be set to "No expiration", but periodic rotation is recommended)
6. Generate and copy the token

Add it as a repo secret:

```bash
gh secret set AGENT_GIST_PAT --repo OWNER/REPO
```

If you skip this, the cleanup workflow will still run but will skip the gist cleanup step.

---

## PAT Rotation

Fine-grained PATs expire after at most 1 year. Rotate them before they expire to avoid agent downtime.

### Rotation procedure (zero downtime)

The key to zero-downtime rotation is to create the new token before revoking the old one, and update all locations that use the token before the old one expires.

#### 1. Generate a new PAT

1. Log in as the bot account
2. Go to **Settings > Developer settings > Personal access tokens > Fine-grained tokens**
3. Click **Generate new token** (do NOT delete the old one yet)
4. Use the same resource owner, repository access, and permissions as the existing token
5. Copy the new token

#### 2. Update the GitHub Actions secret

```bash
gh secret set AGENT_PAT --repo OWNER/REPO
# Paste the NEW token
```

This takes effect immediately for all future workflow runs.

#### 3. Update the runner

SSH into the runner machine and update all locations:

```bash
# Update gh CLI authentication
echo "NEW_TOKEN_HERE" | gh auth login --with-token --hostname github.com

# Verify
gh auth status

# Update git credentials
# Edit ~/.git-credentials and replace the old token with the new one
nano ~/.git-credentials
# Change: https://bot-username:OLD_TOKEN@github.com
# To:     https://bot-username:NEW_TOKEN@github.com

# If you also set GITHUB_TOKEN in ~/.bashrc, update it there too
nano ~/.bashrc
source ~/.bashrc
```

#### 4. Verify everything works

```bash
# Test gh
gh issue list --repo OWNER/REPO

# Test git push (dry run)
cd /tmp && git clone https://github.com/OWNER/REPO.git test-clone && rm -rf test-clone
```

#### 5. Revoke the old PAT

Once you have confirmed the new token works everywhere:

1. Go to **Settings > Developer settings > Personal access tokens > Fine-grained tokens**
2. Find the old token
3. Click **Delete**

### Rotation for AGENT_GIST_PAT (classic)

Follow the same pattern: generate a new classic token with the `gist` scope, update the secret, verify, then delete the old token.

### Setting a reminder

Fine-grained PATs show their expiry date at **Settings > Developer settings > Personal access tokens**. Set a calendar reminder for 2 weeks before expiration to give yourself time to rotate without pressure.

If the PAT expires without rotation, agent workflows will fail with 401 authentication errors. The label on the issue will be set to `agent:failed`.

---

## Security Best Practices

### Minimum permissions

- Grant only the permissions listed above. The bot does not need admin access, deployment access, or access to secrets/environments.
- Scope the PAT to specific repositories rather than "All repositories" when possible.
- Use fine-grained PATs (not classic) for the main `AGENT_PAT`. Classic PATs cannot be scoped to individual repositories.

### Token hygiene

- **Never commit tokens to a repository.** Not in code, not in config files, not in comments. Use GitHub Actions secrets and environment variables.
- **Never paste tokens into issue bodies or PR descriptions.** GitHub may redact known secret formats, but do not rely on this.
- **Store tokens in a password manager.** You need the token value during rotation and runner setup.
- **Use different tokens for different purposes.** The fine-grained PAT (repo operations) and the classic PAT (gist operations) are separate for a reason -- if one is compromised, the other is unaffected.

### Regular rotation

- Rotate the fine-grained PAT before it expires (annually at most)
- Consider rotating more frequently for high-security environments (quarterly)
- Rotate immediately if you suspect a token has been exposed (in logs, screenshots, etc.)
- After rotation, verify the old token is deleted, not just expired

### Runner security

- The runner machine stores the bot's credentials in `~/.git-credentials` and the `gh` auth store. Restrict SSH access to the runner.
- If the runner is shared, be aware that any user on the machine can read the bot's credentials.
- Consider using a dedicated user account on the runner for the GitHub Actions service, separate from interactive login accounts.

### Monitoring

- Periodically check the bot account's activity at `https://github.com/BOT_USERNAME` to ensure it is only performing expected actions.
- Review the bot's PAT usage in **Settings > Developer settings > Personal access tokens** -- GitHub shows when each token was last used.
- If the bot starts behaving unexpectedly, revoke the PAT immediately and investigate before issuing a new one.
