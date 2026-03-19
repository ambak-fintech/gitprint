#!/bin/bash
# Gitprint — Copilot CLI postToolUse Hook
# Fires after each tool use in a Copilot CLI session
# Incrementally tracks file edits in .git/gitprint-copilot-pending.json
# Data is consumed by copilot-stop.sh when the session ends

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:copilot:post-tool] $*" >&2; }
log_err() { echo "[gitprint:copilot:post-tool] ERROR: $*" >&2; }

INPUT=$(cat)

# ─── Parse tool info from stdin ───
TOOL_DATA=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      const toolName = j.toolName || '';

      // Only track file-editing tools
      const tracked = ['replace_string_in_file', 'multi_replace_string_in_file', 'create_file'];
      if (!tracked.includes(toolName)) {
        console.log(JSON.stringify({ skip: true }));
        return;
      }

      // toolArgs is a JSON string — double-parse
      let args = {};
      try {
        args = typeof j.toolArgs === 'string' ? JSON.parse(j.toolArgs) : (j.toolArgs || {});
      } catch(e) {
        args = {};
      }

      console.log(JSON.stringify({
        skip: false,
        toolName,
        args,
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

PENDING_FILE="$GIT_DIR/gitprint-copilot-pending.json"

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

  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\.\//, '');
    const cwd = toolData.cwd || process.cwd();
    if (fp.startsWith(cwd + '/')) fp = fp.slice(cwd.length + 1);
    if (fp.includes('node_modules')) return;
    if (!pending[fp]) pending[fp] = { added: 0, removed: 0 };
    pending[fp].added += added;
    pending[fp].removed += removed;
  };

  const name = toolData.toolName;
  const args = toolData.args || {};

  if (name === 'replace_string_in_file') {
    const fp = args.path || args.file_path || '';
    const oldStr = args.old_string || args.old_str || '';
    const newStr = args.new_string || args.new_str || '';
    trackFile(fp, countLines(newStr), countLines(oldStr));
  }

  if (name === 'multi_replace_string_in_file') {
    const fp = args.path || args.file_path || '';
    for (const edit of (args.edits || args.replacements || [])) {
      const oldStr = edit.old_string || edit.old_str || '';
      const newStr = edit.new_string || edit.new_str || '';
      trackFile(fp, countLines(newStr), countLines(oldStr));
    }
  }

  if (name === 'create_file') {
    const fp = args.path || args.file_path || '';
    trackFile(fp, countLines(args.content || ''), 0);
  }

  fs.writeFileSync(pendingPath, JSON.stringify(pending));
" 2>/dev/null || log_err "failed to update pending file"

log "updated pending file"
exit 0
