#!/bin/bash
# Gitprint — Cursor afterFileEdit Hook
# Fires after each file edit in a Cursor session.
# Tracks per-file AI line counts in .git/gitprint-cursor-pending.json
# Data is consumed by cursor-stop.sh when the session ends.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:cursor:post-tool] $*" >&2; }
log_err() { echo "[gitprint:cursor:post-tool] ERROR: $*" >&2; }

INPUT=$(cat)

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || { log "not in a git repo"; exit 0; }
PENDING_FILE="$GIT_DIR/gitprint-cursor-pending.json"

node -e "
  const fs = require('fs');
  const path = require('path');

  let j = {};
  try { j = JSON.parse(process.argv[1]); } catch { process.exit(0); }

  // afterFileEdit provides: file_path, old_content, new_content (or filePath, oldContent, newContent)
  const filePath = j.file_path || j.filePath || j.path || '';
  const oldContent = j.old_content || j.oldContent || j.old_text || j.oldText || '';
  const newContent = j.new_content || j.newContent || j.new_text || j.newText || '';

  if (!filePath) process.exit(0);

  const countLines = (str) => (!str || String(str).length === 0) ? 0 : String(str).split('\n').length;
  const added = countLines(newContent);
  const removed = countLines(oldContent);

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

  let pending = {};
  try { pending = JSON.parse(fs.readFileSync('$PENDING_FILE', 'utf8')); } catch {}

  if (!pending[fp]) pending[fp] = { added: 0, removed: 0 };
  pending[fp].added += added;
  pending[fp].removed += removed;

  fs.writeFileSync('$PENDING_FILE', JSON.stringify(pending));
" "$INPUT" 2>/dev/null || log_err "failed to update pending file"

log "updated pending file"
exit 0
