#!/bin/bash
# Gitprint — Augment Code PostToolUse Hook
# Fires after each file-editing tool use in an Augment Code session
# Incrementally tracks file edits in .git/gitprint-augment-pending.json
# so post-commit can attach the delta to the next commit.

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:augment:post-tool] $*" >&2; }
log_err() { echo "[gitprint:augment:post-tool] ERROR: $*" >&2; }

INPUT=$(cat)

# ─── Parse tool info from stdin ───
TOOL_DATA=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      const toolName = j.tool_name || j.toolName || '';

      // Only track file-editing tools
      const tracked = ['str-replace-editor', 'save-file', 'create-file', 'write-file',
                        'str_replace_editor', 'save_file', 'create_file', 'write_file'];
      if (!tracked.includes(toolName)) {
        console.log(JSON.stringify({ skip: true }));
        return;
      }

      // tool_input may be a string or object
      let args = {};
      try {
        const raw = j.tool_input || j.toolArgs || j.args || {};
        args = typeof raw === 'string' ? JSON.parse(raw) : raw;
      } catch(e) {
        args = {};
      }

      // Also check file_changes array
      const fileChanges = j.file_changes || [];

      console.log(JSON.stringify({
        skip: false,
        toolName,
        args,
        fileChanges,
        cwd: j.cwd || ''
      }));
    } catch(e) {
      console.log(JSON.stringify({ skip: true }));
    }
  });
")

# Check if we should skip this tool
SKIP=$(echo "$TOOL_DATA" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).skip ? 'yes' : 'no'); }
    catch(e) { console.log('yes'); }
  });
")

if [ "$SKIP" = "yes" ]; then
  log "skipping non-tracked tool"
  exit 0
fi

# ─── Must be in a git repo ───
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
if [ -z "$GIT_DIR" ]; then
  log "not in a git repo"
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_HELPER="$REPO_ROOT/.github/hooks/gitprint-state.js"
STATE_FILES=$(node - "$STATE_HELPER" "$REPO_ROOT" "$GIT_DIR" <<'NODEEOF'
const state = require(process.argv[2]);
const context = state.resolveRepoStateContext({ cwd: process.argv[3], gitDir: process.argv[4], env: process.env });
const paths = state.resolveToolStatePaths(context, 'augment');
process.stdout.write(`${paths.pendingFile}\n${paths.activeFile}`);
NODEEOF
)
PENDING_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '1p')
ACTIVE_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '2p')

# ─── Extract file stats and merge into pending file ───
node - "$STATE_HELPER" "$PENDING_FILE" "$TOOL_DATA" 2>/dev/null <<'NODEEOF'
  const state = require(process.argv[2]);
  const pendingPath = process.argv[3];
  const toolData = JSON.parse(process.argv[4]);

  const countLines = (str) => {
    if (!str) return 0;
    const s = String(str);
    return s.length === 0 ? 0 : s.split('\n').length;
  };

  // Read existing pending data
  let pending = state.readJson(pendingPath, {});

  const repoRoot = (() => { try { return require('child_process').execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim(); } catch { return toolData.cwd || process.cwd(); } })();
  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\.\//, '');
    if (fp.startsWith('/')) {
      if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1);
      else return;
    } else {
      const cwd = toolData.cwd || process.cwd();
      const abs = require('path').resolve(cwd, fp);
      if (abs.startsWith(repoRoot + '/')) fp = abs.slice(repoRoot.length + 1);
    }
    if (fp.includes('node_modules')) return;
    if (!pending[fp]) pending[fp] = { added: 0, removed: 0 };
    pending[fp].added += added;
    pending[fp].removed += removed;
  };

  const name = toolData.toolName;
  const args = toolData.args || {};

  // str-replace-editor / str_replace_editor
  if (/^str[-_]replace[-_]editor$/.test(name)) {
    const fp = args.file_path || args.path || '';
    const oldStr = args.old_string || args.old_str || '';
    const newStr = args.new_string || args.new_str || '';
    trackFile(fp, countLines(newStr), countLines(oldStr));
  }

  // save-file / create-file / write-file
  if (/^(save|create|write)[-_]file$/.test(name)) {
    const fp = args.file_path || args.path || '';
    trackFile(fp, countLines(args.content || ''), 0);
  }

  // Process file_changes array if present
  for (const fc of (toolData.fileChanges || [])) {
    const fp = fc.file_path || fc.path || '';
    trackFile(fp, fc.lines_added || 0, fc.lines_removed || 0);
  }

  state.writeJsonAtomic(pendingPath, pending);
NODEEOF
if [ $? -ne 0 ]; then log_err "failed to update pending file"; fi

node - "$STATE_HELPER" "$ACTIVE_FILE" "$TOOL_DATA" 2>/dev/null <<'NODEEOF'
  const state = require(process.argv[2]);
  const activePath = process.argv[3];
  const toolData = JSON.parse(process.argv[4]);

  state.writeJsonAtomic(activePath, {
    cwd: toolData.cwd || process.cwd(),
    updated: new Date().toISOString(),
  });
NODEEOF
if [ $? -ne 0 ]; then log_err "failed to update active marker"; fi

log "updated pending file"
exit 0
