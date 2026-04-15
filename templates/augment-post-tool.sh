#!/bin/bash
# Gitprint — Augment Code PostToolUse Hook
# Fires after each tool use in an Augment Code session
# Incrementally tracks file edits in .git/gitprint-augment-pending.json
# Data is consumed by augment-stop.sh when the session ends

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

PENDING_FILE="$GIT_DIR/gitprint-augment-pending.json"

# ─── Extract file stats and merge into pending file ───
node -e "
  const fs = require('fs');
  const toolData = $TOOL_DATA;
  const pendingPath = '$PENDING_FILE';

  const countLines = (str) => {
    if (!str) return 0;
    const s = String(str);
    return s.length === 0 ? 0 : s.split('\n').length;
  };

  // Read existing pending data
  let pending = {};
  try {
    pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
  } catch(e) {
    pending = {};
  }

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
    if (fp.includes('node_modules') || fp.includes('.ai-stats') || /^\.(claude|github|gitprint|cursor|gemini|windsurf|augment|opencode)\//.test(fp)) return;
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

  fs.writeFileSync(pendingPath, JSON.stringify(pending));
" 2>/dev/null || log_err "failed to update pending file"

log "updated pending file"
exit 0
