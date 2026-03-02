# Gitprint

AI code attribution for pull requests.

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

## License

MIT
