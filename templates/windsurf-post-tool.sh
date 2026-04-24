#!/bin/bash
# Gitprint — Windsurf post_write_code Hook
# Fires after each file write/modification in a Windsurf Cascade session.
# Tracks per-file AI line counts in .git/gitprint-windsurf-pending.json
# Data is consumed by windsurf-stop.sh when the session ends.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:windsurf:post-tool] $*" >&2; }
log_err() { echo "[gitprint:windsurf:post-tool] ERROR: $*" >&2; }

INPUT=$(cat)

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || { log "not in a git repo"; exit 0; }
PENDING_FILE="$GIT_DIR/gitprint-windsurf-pending.json"

node -e "
  const fs = require('fs');
  const path = require('path');

  let j = {};
  try { j = JSON.parse(process.argv[1]); } catch { process.exit(0); }

  // post_write_code provides: tool_info.file_path, tool_info.edits[]
  const toolInfo = j.tool_info || {};
  const filePath = toolInfo.file_path || toolInfo.filePath || '';
  const edits = toolInfo.edits || [];

  if (!filePath) process.exit(0);

  const countLines = (str) => (!str || String(str).length === 0) ? 0 : String(str).split('\n').length;

  const repoRoot = (() => {
    try { return require('child_process').execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim(); }
    catch { return process.cwd(); }
  })();

  let fp = filePath.replace(/^\.\//, '');
  if (fp.startsWith('/')) {
    if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1);
    else process.exit(0);
  } else {
    const abs = path.resolve(process.cwd(), fp);
    if (abs.startsWith(repoRoot + '/')) fp = abs.slice(repoRoot.length + 1);
  }
  if (fp.includes('node_modules') || fp.includes('.git/')) process.exit(0);

  let added = 0, removed = 0;
  if (edits.length > 0) {
    for (const edit of edits) {
      added += countLines(edit.new_string || edit.newString || edit.new_str || '');
      removed += countLines(edit.old_string || edit.oldString || edit.old_str || '');
    }
  } else {
    // Fallback: whole-file write — count content lines
    const content = toolInfo.content || toolInfo.file_text || '';
    added = countLines(content);
  }

  let pending = {};
  try { pending = JSON.parse(fs.readFileSync('$PENDING_FILE', 'utf8')); } catch {}

  if (!pending[fp]) pending[fp] = { added: 0, removed: 0 };
  pending[fp].added += added;
  pending[fp].removed += removed;

  fs.writeFileSync('$PENDING_FILE', JSON.stringify(pending));
" "$INPUT" 2>/dev/null || log_err "failed to update pending file"

log "updated pending file"
exit 0
