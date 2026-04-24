# Gitprint

AI code attribution for pull requests — powered by Git Notes.

Track how much code in your PRs was written by AI tools like Claude Code, Cursor, Copilot, Gemini CLI, Windsurf, Augment Code, Codex, and OpenCode. Every push automatically posts a live attribution report as a PR comment.

---

## Support Matrix

| Tool | Success Level | What Works Well | Main Gotchas |
|------|---------------|-----------------|--------------|
| Claude Code | High | Commit-time file and session attribution via `PostToolUse` + `post-commit` + leftover `Stop` delta | Cost is still model-family heuristic |
| Gemini CLI | High | Commit-time file and session attribution via `AfterTool` + `post-commit` + leftover `SessionEnd` delta | Depends on Gemini transcript schema staying compatible |
| Windsurf | Medium-High | Commit-time file attribution from recurring transcript hook + `post-commit` delta parsing | No dedicated session-end hook; uncommitted tail work can remain pending until a later response or commit; token/cost data is effectively unavailable |
| Codex | Medium-High | Commit-time transcript-delta attachment from recurring turn-scoped `Stop` hook | File attribution comes from transcript `apply_patch`; `PostToolUse` is currently only useful for `Bash`; hooks are experimental |
| Copilot CLI | Medium | Commit-time file attribution from `postToolUse`; later session/token metadata from `sessionEnd` | Session discovery is heuristic and exact commit-time session metadata attribution is not possible |
| Augment Code | Medium | Commit-time file attribution from `PostToolUse`; later leftover delta/session entry on `Stop` | No token data, so token/cost fields remain `0`; exact commit-time session metadata attribution is not possible |
| OpenCode | Medium | Commit-time file attribution from `tool.execute.after`; later token/session flush on `session.idle` | Session metadata still arrives later than commit time; depends on current OpenCode plugin API shape |
| Cursor | Low-Medium | Best-effort note creation on `stop`, then uploader reuse | No earlier hook in current integration surface, so exact commit-time attachment is not guaranteed |

Notes:
- `High` means the tool is closest to the target lifecycle: capture during the session, attach on `git post-commit`, and only leave true tail work for the final hook.
- `Medium` means commit-time file attribution works, but some session metadata still arrives later.
- `Low-Medium` means only a best-effort fallback is currently possible.

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
- Remove the old legacy GitHub Actions workflow at `.github/workflows/gitprint.yml` if it exists
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

Gitprint can post detailed attribution data to an external AI engineering platform from the local `post-commit` hook.

### Recommended local setup

Set the platform URL and token once per developer machine using global git config:

```bash
git config --global gitprint.platformUrl "https://platform.example.com"
git config --global gitprint.platformToken "your-token"
```

This keeps secrets out of the repo and lets all local Gitprint hooks use the same credentials.

> **Security note:** Global git config stores the token in plain text on disk. If you want a safer setup, prefer environment variables injected by your shell or a local secret manager.

`gitprint init` does not require the platform token prompt anymore when global config or environment variables are already set.

### Credential source order

The local `post-commit` hook reads platform credentials in this order:

1. `AI_PLATFORM_URL` and `AI_PLATFORM_TOKEN`
2. `AI_PLATFORM_URL` and `AI_PLATFORM_KEY` (`AI_PLATFORM_KEY` is accepted as a compatibility alias)
3. `git config --global gitprint.platformUrl`
4. `git config --global gitprint.platformToken`
5. Repo-local `.git/gitprint-config` fallback

### Alternative environment-variable setup

If you prefer environment variables instead of global git config:

```bash
export AI_PLATFORM_URL="https://platform.example.com"
export AI_PLATFORM_TOKEN="your-token"
```

### Legacy repo-local fallback

Older installs may still use a local `.git/gitprint-config` file with:

| Key | Value |
|-----|-------|
| `AI_PLATFORM_URL` | The base URL of your AI platform (e.g. `https://platform.example.com`) |
| `AI_PLATFORM_TOKEN` | Your API key / bearer token for the platform |

This still works, but global git config is the recommended rollout path for local-only ingestion.

> **Note:** If the URL or token is missing, local platform ingest is skipped. Git note attachment still continues normally.

### What gets posted

On each local commit where platform credentials are available, Gitprint sends a JSON payload to `POST {AI_PLATFORM_URL}/api/ingest/push` containing:
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
2. Tool/session hooks capture transcript paths or file-edit deltas as local git metadata state
3. `git post-commit` attaches the newest available AI delta to the commit that was just created whenever the tool supports that lifecycle
4. Final session hooks add any leftover uncommitted delta or delayed session metadata
5. When you push, the GitHub Action reads notes across all commits in your PR
6. It posts a detailed attribution report as a PR comment — updated on every subsequent push

---

## License

MIT
