# Gitprint

AI code attribution for pull requests — powered by Git Notes.

## What this project does

Gitprint tracks how much code in a PR was written by AI (Claude Code, Cursor, Copilot, Gemini CLI, Windsurf, Augment Code, OpenCode). It parses AI tool session transcripts to extract exact line-level attribution, stores stats as Git Notes (not files), and posts an auto-updating report comment on every PR via GitHub Actions.

## Architecture

```
templates/stop.sh              → Gets copied into user's .claude/hooks/ on `gitprint init`
templates/cursor-stop.sh       → Gets copied into user's .cursor/hooks/ on `gitprint init`
templates/copilot-stop.sh      → Gets copied into user's .github/hooks/ on `gitprint init`
templates/copilot-post-tool.sh → Gets copied into user's .github/hooks/ on `gitprint init`
templates/gemini-stop.sh       → Gets copied into user's .gemini/hooks/ on `gitprint init`
templates/windsurf-stop.sh     → Gets copied into user's .windsurf/hooks/ on `gitprint init`
templates/augment-stop.sh      → Gets copied into user's .augment/hooks/ on `gitprint init`
templates/augment-post-tool.sh → Gets copied into user's .augment/hooks/ on `gitprint init`
templates/opencode-plugin.js   → Gets copied into user's .opencode/plugins/ on `gitprint init`
templates/gitprint.yml         → Gets copied into user's .github/workflows/
bin/cli.js                     → CLI tool (gitprint init/status/doctor/uninstall)
setup.sh                       → Alternative curl-based installer (no npm)
```

### Data flow

1. AI tool session ends → stop hook fires (or plugin runs)
2. Hook parses transcript JSONL → extracts tokens, models, per-file AI lines
3. Data stored as Git Note (`refs/notes/gitprint`) on HEAD commit
4. `git push` auto-pushes notes via refspec config
5. GitHub Action reads all notes in PR commit range → aggregates → posts PR comment

### Key design decisions

- **Git Notes over JSON file**: No merge conflicts, no cleanup commits, no extra workflow jobs. Notes are metadata outside the working tree.
- **Session transcript parsing over heuristics**: We parse actual tool_use blocks (Edit, Write, MultiEdit) from transcripts for exact attribution. We don't guess from code patterns.
- **Accumulation across sessions**: Multiple AI tool sessions on the same branch accumulate stats. Notes on different commits get merged by the workflow.
- **Notes namespace**: `refs/notes/gitprint` — isolated from default git notes.
- **One hook per tool**: Each AI tool has its own hook script(s). Shared logic is duplicated, not abstracted. Copilot and Augment use two hooks (postToolUse + sessionEnd). OpenCode uses a JS plugin instead of bash.
- **TOOLS registry in cli.js**: `bin/cli.js` uses a data-driven `TOOLS` array. Adding a new tool = ~25 lines of config in the registry, not ~150 lines across 3 functions.
- **Download-based setup.sh**: `setup.sh` downloads hook scripts from GitHub raw URLs instead of embedding them as heredocs. Keeps the installer under 300 lines regardless of how many tools are supported.

## How the stop hooks work

### Claude Code hook (`templates/stop.sh`)

The hook receives JSON on stdin with `transcript_path` and `session_id`. It:

1. Reads the transcript JSONL file line by line
2. For `assistant` entries with `usage` → accumulates token counts and model info
3. For `tool_use` blocks → matches tool names and extracts file paths + line counts:
   - `Edit` / `str_replace`: counts lines in `old_string` (removed) and `new_string` (added)
   - `MultiEdit`: same, for each edit in the batch
   - `Write` / `Create`: entire file content = AI lines added
4. Calculates `estimated_cost` from token counts + model pricing
5. Merges with any existing note on HEAD
6. Writes combined data as Git Note
7. Pushes notes in background (best-effort)

Sets `"tool": "claude-code"` in session data.

### Cursor hook (`templates/cursor-stop.sh`)

Same architecture as the Claude Code hook but for Cursor's `sessionEnd` hook:

- Receives JSON on stdin with `transcript_path` and `conversation_id` (mapped to `session_id`)
- Parses the same JSONL transcript format for tokens, models, and file edits
- Sets `"tool": "cursor"` in session data
- Includes expanded pricing table (GPT-4o, o1, o3, Gemini rates in addition to Claude)
- Same merge/write/push logic as the Claude Code hook

### Copilot CLI hooks (`templates/copilot-stop.sh` + `templates/copilot-post-tool.sh`)

Copilot CLI's `sessionEnd` hook only provides `{timestamp, cwd, reason}` — no transcript path or session ID. This requires a two-hook architecture:

**`copilot-post-tool.sh` (postToolUse hook):**
- Fires after each tool use during a session
- Receives `{timestamp, cwd, toolName, toolArgs, toolResult}` on stdin
- `toolArgs` is a JSON string requiring double-parse
- Tracks `replace_string_in_file`, `multi_replace_string_in_file`, `create_file`
- Appends file edit stats to `.git/gitprint-copilot-pending.json`

**`copilot-stop.sh` (sessionEnd hook):**
1. Extracts `cwd` from stdin JSON
2. Walks `~/.copilot/session-state/` directories
3. For each, reads `workspace.yaml`, regex-matches `cwd:\s*(.+)` against hook's cwd
4. Among matches, picks dir with most recently modified `events.jsonl`
5. Uses directory basename as `session_id`
6. Parses `events.jsonl` for tokens/models (tries both `prompt_tokens` and `input_tokens` field names)
7. Reads `.git/gitprint-copilot-pending.json` as authoritative file edit data (falls back to events.jsonl)
8. Deletes pending file after reading
9. Same merge/write/push logic as other hooks

Sets `"tool": "copilot"` in session data. Includes expanded pricing table (GPT-4o, o1, o3, Gemini rates).

**Hook registration:** `.github/hooks/gitprint-copilot.json` — standalone file (Copilot CLI reads all `*.json` in `.github/hooks/`)

**Copilot CLI tool names (lowercase):**
`replace_string_in_file`, `multi_replace_string_in_file`, `create_file`, `read_file`, `run_command`

Input fields: `path`, `old_string`, `new_string`, `content`, `edits`/`replacements`

### Gemini CLI hook (`templates/gemini-stop.sh`)

Nearly identical architecture to Claude Code. Gemini CLI's `SessionEnd` hook provides `session_id` + `transcript_path` on stdin.

**Stdin:** `{ "session_id": "...", "transcript_path": "...", "cwd": "...", "hook_event_name": "SessionEnd", "timestamp": "..." }`

**Transcript parsing differences from Claude Code:**
- Token records: `message_update` entries with `{"tokens":{"input":X,"output":Y}}` (not `entry.message.usage`)
- Also handles top-level `usage` objects and Claude-style assistant entries (defensive)
- Tool names: `replace` (not `Edit`), `write_file` (not `Write`)
- Tool params: `file_path`, `old_string`, `new_string`, `content` — same field names

Sets `"tool": "gemini"` in session data. Includes expanded pricing table with Gemini model rates.

**Hook registration:** `.gemini/settings.json` with `SessionEnd` hook config.

**Detection:** `which gemini` OR `~/.gemini/` exists.

### Windsurf hook (`templates/windsurf-stop.sh`)

Single-hook architecture using `post_cascade_response_with_transcript` hook.

**Key limitation:** Windsurf transcripts do **NOT** contain token usage data. File attribution works; cost tracking does not. All token/cost fields output as 0.

**Stdin:** `{ "transcript_path": "...", "trajectory_id": "...", "execution_id": "...", "timestamp": "..." }`

- `trajectory_id` → `session_id`
- Parses transcript JSONL for file edit tool uses (same patterns as other hooks)
- Sets `"tool": "windsurf"` in session data

**Hook registration:** `.windsurf/settings.json` with `post_cascade_response_with_transcript` hook config.

**Detection:** `which windsurf` OR `~/.windsurf/` exists.

### Augment Code hooks (`templates/augment-stop.sh` + `templates/augment-post-tool.sh`)

Two-hook pattern like Copilot. No transcript path, no token data in payloads.

**`augment-post-tool.sh` (PostToolUse hook):**
- Fires after each tool use during a session
- Receives `{ "tool_name": "str-replace-editor", "tool_input": {...}, "file_changes": [...] }` on stdin
- Tool mapping: `str-replace-editor` → extract `file_path`, `old_string`, `new_string`; `save-file`/`create-file` → extract `file_path`, `content`
- Accumulates to `.git/gitprint-augment-pending.json`

**`augment-stop.sh` (Stop hook):**
- Receives `{ "agent_stop_cause": "...", "conversation_id": "..." }` on stdin
- `conversation_id` → `session_id`
- Reads + deletes pending file
- No token tracking (set to 0)
- Sets `"tool": "augment"` in session data
- Skips writing note if no file edits were tracked

**Hook registration:** `.augment/hooks/gitprint-augment.json` — standalone config file.

**Detection:** `which augment` OR `~/.augment/` exists.

### OpenCode plugin (`templates/opencode-plugin.js`)

**Different paradigm:** OpenCode uses JS plugins in `.opencode/plugins/` (auto-loaded), not bash hooks.

**Plugin structure:**
- `tool.execute.after` event: tracks `edit`, `write`, `create`, `multi_edit` tools for file stats
- `message.after` event: tracks token usage if available via plugin API
- `session.idle` event: builds session JSON, merges with existing note, writes git note, pushes in background
- Resets counters after writing to avoid duplicate data across idle cycles

Sets `"tool": "opencode"` in session data.

**Detection:** `which opencode` OR `~/.config/opencode/` exists.

### Hook debugging

All hooks support stderr logging via the `GITPRINT_DEBUG` env var:

```bash
# Enable verbose logging (writes to stderr, safe for hook protocol)
GITPRINT_DEBUG=1 echo '{}' | bash templates/stop.sh

# Errors always log to stderr (no env var needed)
```

- `log()` — only fires when `GITPRINT_DEBUG=1`
- `log_err()` — always fires (errors only)

### Claude Code tool names (capitalized)

Claude Code uses: `Edit`, `MultiEdit`, `Write`, `Create`, `Read`, `Bash`, `Glob`, `Task`

Input fields: `file_path`, `old_string`, `new_string`, `content`

## How the GitHub Action works

Two jobs in `gitprint.yml`:

- **create-pr**: On branch creation → creates draft PR to base branch
- **ai-stats**: On push → fetches notes, reads all notes in `origin/{base}..HEAD` range, aggregates sessions + file stats, calculates AI %, posts/updates PR comment

The workflow uses `GITHUB_TOKEN` (no PAT needed if org has read-write workflow permissions).

Tool icons in workflow: `claude-code` 🟣, `cursor` 🔵, `copilot` ⚪, `gemini` 🔴, `windsurf` 🟢, `augment` 🟡, `opencode` 🟤.

## CLI commands

- `gitprint init [--yes]` — copies templates, merges settings.json, configures git notes refspec. Prompts for base branch and each optional tool (use `--yes` to skip prompts)
- `gitprint status` — reads notes on current branch, shows summary in terminal (tokens, cost, tools, files)
- `gitprint report [file]` — generates markdown report file (default: gitprint-report.md) with full attribution details
- `gitprint doctor` — checks hook exists + executable, hook dry-run test, settings.json has hook, workflow exists, origin remote, git config has notes refspec, status of all installed optional tools, node.js available
- `gitprint uninstall` — removes all tool hooks/configs, removes workflow, cleans up empty directories

### CLI flags

- `--yes` / `-y` — skip all interactive prompts, use detected defaults. Auto-enabled when stdin is not a TTY (e.g., piped input, CI)

### TOOLS registry (cli.js)

All tool-specific logic in `bin/cli.js` is driven by the `TOOLS` array at the top of the file. Each entry defines:

```javascript
{
  id: 'tool-id',                       // used in session data "tool" field
  name: 'Tool Name',                   // display name
  required: true/false,                // true = always install (Claude Code only)
  detect: (root) => boolean,           // auto-detection logic
  detectHint: 'description',           // shown when not detected
  hooks: [{ src, dest, noExec? }],     // files to copy from templates/
  config: { type, ... },               // settings.json / hooks.json / standalone-json / none
  doctorChecks: [...],                  // file-exec, file-exists, dry-run, settings-json, hooks-json, standalone-json-check
  uninstallFiles: [...],               // files to delete
  uninstallConfig: { ... },            // settings/hooks cleanup logic
  cleanupDir: '...',                   // directory to remove if empty after uninstall
  addPaths: ['.tool'],                 // dirs to include in commit hint
}
```

## Cursor integration

### Hook registration

Cursor hooks live in `.cursor/hooks/` and are registered in `.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "command": "hooks/gitprint-stop.sh"
      }
    ]
  }
}
```

The hook file is named `gitprint-stop.sh` (not `stop.sh`) to avoid collisions with other tools.

### Detection in CLI

- `gitprint init` auto-detects `.cursor/` directory and prompts to install Cursor hook
- `gitprint doctor` shows Cursor hook status as warnings (informational, not errors)
- `gitprint uninstall` cleans up both Claude Code and Cursor hooks

## Copilot CLI integration

### Hook registration

Copilot CLI hooks live in `.github/hooks/` and are registered via JSON config files. Copilot reads all `*.json` files in that directory.

```json
{
  "version": 1,
  "hooks": {
    "sessionEnd": [{
      "type": "command",
      "bash": ".github/hooks/gitprint-copilot-stop.sh",
      "timeoutSec": 30
    }],
    "postToolUse": [{
      "type": "command",
      "bash": ".github/hooks/gitprint-copilot-post-tool.sh",
      "timeoutSec": 10
    }]
  }
}
```

### Session discovery

Unlike Claude Code and Cursor, Copilot's `sessionEnd` hook doesn't provide a transcript path. The stop hook discovers session data by:

1. Walking `~/.copilot/session-state/` directories
2. Reading `workspace.yaml` in each, matching `cwd` field against the hook's working directory
3. Picking the most recently modified `events.jsonl` as the active session

### Known issues

- `events.jsonl` schema is undocumented — all field access is defensive with fallbacks
- `workspace.yaml` is parsed via regex (`cwd:\s*(.+)`) instead of a YAML parser
- `sessionEnd` may fire per-prompt in interactive mode (deduped by session_id in merge logic)
- Pending file (`.git/gitprint-copilot-pending.json`) may be left behind on crash — overwritten by next session

### Detection in CLI

- `gitprint init` auto-detects `which copilot` or `~/.copilot/` directory and prompts to install
- `gitprint doctor` shows Copilot hook status as warnings (informational, not errors)
- `gitprint uninstall` cleans up all three Copilot files and removes `.github/hooks/` if empty

## Development

```bash
git clone https://github.com/ambak-fintech/gitprint
cd gitprint
npm link    # makes `gitprint` command available globally for testing
```

No build step. No dependencies. Pure Node.js + bash.

### Testing changes

1. Make changes to hook scripts in `templates/`
2. Go to a test repo, run `gitprint init` (re-copies templates)
3. Use an AI tool → exit session → check git notes: `git notes --ref=gitprint show HEAD`
4. Push → check PR comment on GitHub

### Adding a new AI tool parser

Each AI tool has its own hook script. To add support for another tool:

1. Create `templates/<tool>-stop.sh` (or `.js` for JS plugins) with the tool's transcript parser
2. Set `"tool": "<tool-name>"` in the session data
3. Reuse the same merge/write/push logic (bottom half of existing hooks)
4. Add a TOOLS entry in `bin/cli.js` — ~25 lines of config
5. Add prompts in `setup.sh` — ~30 lines of download + config logic

The workflow doesn't care which tool generated the data — it just reads Git Notes.

## File format (Git Note content)

```json
{
  "sessions": [
    {
      "session_id": "uuid",
      "tool": "claude-code",
      "timestamp": "ISO8601",
      "input_tokens": 25,
      "output_tokens": 1200,
      "cache_creation_tokens": 48000,
      "cache_read_tokens": 200000,
      "estimated_cost": 1.2345,
      "turns": 11,
      "models": {
        "claude-opus-4-6": {
          "input_tokens": 248025,
          "output_tokens": 1200,
          "turns": 11
        }
      }
    }
  ],
  "ai_files": [
    {
      "file": "src/components/Button.tsx",
      "ai_lines_added": 45,
      "ai_lines_removed": 12
    }
  ]
}
```

## Roadmap

- [x] Token cost estimation ($ per model)
- [x] `gitprint report` command — markdown export
- [x] Multi-tool schema (`tool` field in session data)
- [x] Cursor session parser
- [x] Copilot CLI parser (two-hook architecture: postToolUse + sessionEnd)
- [x] Gemini CLI / Antigravity parser
- [x] Windsurf parser (file attribution only — no token data)
- [x] Augment Code parser (two-hook architecture: PostToolUse + Stop)
- [x] OpenCode plugin (JS plugin, not bash hook)
- [ ] `gitprint leaderboard` — team-wide AI stats
- [ ] GitHub App (one-click install from Marketplace)
- [ ] Dashboard web UI
