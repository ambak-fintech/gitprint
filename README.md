# Gitprint

AI code attribution for pull requests — powered by Git Notes.

Track how much code in your PRs was written by AI tools. Gitprint parses session transcripts for exact line-level attribution, stores stats as Git Notes, and posts an auto-updating report on every PR via GitHub Actions.

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

## Supported AI Tools

| Tool | Attribution | Token Tracking | Hook Type |
|------|------------|----------------|-----------|
| Claude Code | Yes | Yes | Session end |
| Cursor | Yes | Yes | Session end |
| Copilot CLI | Yes | Yes | Post tool use + Session end |
| Gemini CLI | Yes | Yes | Session end |
| Windsurf | Yes | No | Post cascade response |
| Augment Code | Yes | No | Post tool use + Stop |
| OpenCode | Yes | Partial | JS plugin |

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

## License

MIT
