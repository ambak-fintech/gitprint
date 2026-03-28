# Gitprint

[![gitcgr](https://gitcgr.com/badge/ambak-fintech/gitprint.svg)](https://gitcgr.com/ambak-fintech/gitprint)

AI code attribution for pull requests — powered by Git Notes.

Track how much code in your PRs was written by AI tools like Claude Code, Cursor, Copilot, Gemini CLI, Windsurf, Augment Code, and OpenCode.

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

## Quick Start

```bash
npm install -g @ambak/gitprint
```

```bash
cd your-project
gitprint init
git add .claude .github && git commit -m "chore: add gitprint"
git push
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `gitprint init` | Install hooks + workflow in current repo |
| `gitprint status` | Show AI stats for current branch |
| `gitprint doctor` | Check if everything is configured correctly |
| `gitprint report` | Generate markdown report with full attribution details |
| `gitprint uninstall` | Remove Gitprint from current repo |

## Configuration

### Custom base branch

The init command auto-detects your base branch. To change it later, edit `.github/workflows/gitprint.yml` and replace all instances of the base branch name.

### Custom runner

Replace `runs-on: ubuntu-latest` with your preferred runner:

```yaml
runs-on: blacksmith-4vcpu-ubuntu-2404  # or self-hosted, etc.
```

### Skip auto-PR creation

Remove the `create-pr` job from `gitprint.yml` if you don't want automatic draft PRs.

## How It Works

1. AI tool session ends → hook fires automatically
2. Hook parses session transcript → extracts tokens, models, and per-file AI lines
3. Data stored as a Git Note on the commit (no files added to your repo)
4. On push, GitHub Action reads notes across all PR commits → posts an attribution report as a PR comment

## Contributing

Contributions are welcome! Run `gitprint doctor` to verify your setup after making changes.

## License

MIT
