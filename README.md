# Gitprint

AI code attribution for pull requests — powered by Git Notes.

Track how much code in your PRs was written by AI tools like Claude Code, Cursor, Copilot, Gemini CLI, Windsurf, Augment Code, and OpenCode. Every push automatically posts a live attribution report as a PR comment.

---

## Supported Tools

| Tool | Token Tracking | File Attribution |
|------|:-:|:-:|
| Claude Code | Yes | Yes |
| Cursor | Yes | Yes |
| Copilot CLI | Yes | Yes |
| Gemini CLI | Yes | Yes |
| Windsurf | No | Yes |
| Augment Code | No | Yes |
| OpenCode | Yes | Yes |

---

## Installation

Install the CLI globally via npm:

```bash
npm install -g @ambak/gitprint
```

---

## Setup

### Step 1 — Run `gitprint init` in your repo

Navigate to your project root and run:

```bash
cd your-project
gitprint init
```

This will:
- Detect which AI tools you have installed and install the relevant hooks
- Add the GitHub Actions workflow at `.github/workflows/gitprint.yml`
- Create `.gitprint/branch.json` to track branch parentage for accurate auto-PR targeting
- Auto-detect your base branch (`main`, `staging`, `develop`, etc.)

### Step 2 — Commit and push

```bash
git add .claude .github .gitprint
git commit -m "chore: add gitprint"
git push
```

> **Note:** Only commit the directories relevant to the tools you use. `gitprint init` will tell you exactly which paths to add.

### Step 3 — Verify your setup

```bash
gitprint doctor
```

This checks that all hooks are installed correctly, configs are wired up, and the workflow file is present.

---

## GitHub Actions Workflow

`gitprint init` installs `.github/workflows/gitprint.yml` which runs two jobs on every push:

| Job | Trigger | What it does |
|-----|---------|--------------|
| `create-pr` | First push of a new branch | Creates a draft PR targeting the correct parent branch |
| `ai-stats` | Every push | Posts/updates an AI attribution report as a PR comment |

The workflow requires these GitHub permissions (already set in the file):

```yaml
permissions:
  pull-requests: write
  contents: write
```

---

## Configuring Auto-PR (Optional)

By default, auto-PR creation is **disabled**. To enable it, add a repository variable in GitHub.

### How to add the `GITPRINT_AUTO_PR` variable

1. Go to your GitHub repository
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click the **Variables** tab
4. Click **New repository variable**
5. Set:
   - **Name:** `GITPRINT_AUTO_PR` *(exact case — all uppercase)*
   - **Value:** `true`
6. Click **Add variable**

![Variables tab location: Settings → Secrets and variables → Actions → Variables]

> **Important:** The variable name must be exactly `GITPRINT_AUTO_PR` (all uppercase). GitHub variables are case-sensitive — `Gitprint_auto_pr` will not work.

### How auto-PR works

- Fires **once** — on the very first push of a branch to the remote (the `create` event)
- Reads `.gitprint/branch.json` to find the exact parent branch the new branch was created from
- Falls back to GitHub API `compareCommits` if `branch.json` is not present
- Creates a **draft PR** targeting the parent branch with the `auto-pr` label
- Skips base branches: `main`, `master`, `develop`, `staging`, `pre_release_master`

### To disable auto-PR

Go to **Settings** → **Secrets and variables** → **Actions** → **Variables**, find `GITPRINT_AUTO_PR`, and either delete it or set the value to anything other than `true`.

### Re-triggering auto-PR for an existing branch

The `create` event fires only once per branch. If you pushed a branch before enabling the variable, re-trigger it by deleting and re-pushing:

```bash
git push origin --delete your-branch-name
git push origin your-branch-name
```

---

## Configuring the AI Engineering Platform (Optional)

Gitprint can post detailed attribution data to an external AI engineering platform on every push.

### How to add the secret keys

1. Go to your GitHub repository
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click the **Secrets** tab
4. Add the following two secrets:

| Secret Name | Value |
|-------------|-------|
| `AI_PLATFORM_URL` | The base URL of your AI platform (e.g. `https://platform.example.com`) |
| `AI_PLATFORM_KEY` | Your API key / bearer token for the platform |

To add each secret:
- Click **New repository secret**
- Enter the name and value
- Click **Add secret**

> **Note:** If either secret is missing, the platform push step is silently skipped — the rest of the workflow continues normally.

### What gets posted

On every push to a branch with an open PR, Gitprint sends a JSON payload to `POST {AI_PLATFORM_URL}/api/ingest/push` containing:
- Repository and branch info
- All AI sessions (tool, model, tokens, cost, turns)
- Per-file AI vs human line attribution
- Per-commit breakdown with file-level stats

---

## CLI Commands

| Command | Description |
|---------|-------------|
| `gitprint init` | Install hooks + workflow in current repo |
| `gitprint status` | Show AI stats for current branch |
| `gitprint report [file]` | Generate a markdown attribution report |
| `gitprint doctor` | Check if everything is configured correctly |
| `gitprint update` | Update Gitprint to the latest version |
| `gitprint uninstall` | Remove Gitprint from current repo |

**Options:**

| Flag | Description |
|------|-------------|
| `--yes` / `-y` | Skip all prompts, use defaults |

---

## Configuration

### Custom base branch

`gitprint init` auto-detects your base branch. To change it after setup, edit `.github/workflows/gitprint.yml` and replace `BASE_BRANCH_PLACEHOLDER` with your branch name, or set it in git config:

```bash
git config gitprint.baseBranch staging
```

Then re-run `gitprint init` to regenerate the workflow with the new base.

### Custom runner

Replace `runs-on: ubuntu-latest` in `.github/workflows/gitprint.yml` with your preferred runner:

```yaml
runs-on: blacksmith-4vcpu-ubuntu-2404
# or
runs-on: self-hosted
```

---

## How It Works

1. You write code with an AI tool (Claude Code, Cursor, Copilot, etc.)
2. When the AI session ends, a hook fires automatically
3. The hook parses the session transcript → extracts tokens, models used, and per-file AI line counts
4. This data is stored as a **Git Note** on the current commit (no extra files added to your repo)
5. When you push, the GitHub Action reads notes across all commits in your PR
6. It posts a detailed attribution report as a PR comment — updated on every subsequent push

---

## License

MIT
