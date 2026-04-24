#!/bin/bash
# Gitprint — OpenAI Codex PostToolUse Hook
# Fires after each tool use in a Codex session.
# Tracks apply_patch file edits incrementally in .git/gitprint-codex-pending.json
# Data is consumed by codex-stop.sh when the session ends.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:codex:post-tool] $*" >&2; }
log_err() { echo "[gitprint:codex:post-tool] ERROR: $*" >&2; }

INPUT=$(cat)

# ─── Parse tool info ───
TOOL_DATA=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      const toolName = (j.tool || j.tool_name || j.name || '').toLowerCase();

      if (!toolName.includes('apply_patch') && !toolName.includes('write_file') && !toolName.includes('create_file')) {
        console.log(JSON.stringify({ skip: true }));
        return;
      }

      const args = j.input || j.tool_input || j.arguments || j.args || {};
      console.log(JSON.stringify({ skip: false, toolName, args, cwd: j.cwd || '' }));
    } catch(e) {
      console.log(JSON.stringify({ skip: true }));
    }
  });
")

SKIP=$(echo "$TOOL_DATA" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).skip ? 'yes' : 'no'); } catch { console.log('yes'); } });
")

[ "$SKIP" = "yes" ] && { log "skipping non-tracked tool"; exit 0; }

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || { log "not in a git repo"; exit 0; }
PENDING_FILE="$GIT_DIR/gitprint-codex-pending.json"

node -e "
  const fs = require('fs');
  const toolData = $TOOL_DATA;
  const pendingPath = '$PENDING_FILE';

  const countLines = (str) => (!str || String(str).length === 0) ? 0 : String(str).split('\n').length;

  let pending = {};
  try { pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8')); } catch {}

  const repoRoot = (() => {
    try { return require('child_process').execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim(); }
    catch { return toolData.cwd || process.cwd(); }
  })();

  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\.\//, '').replace(/^a\/|^b\//, '');
    if (fp.startsWith('/')) {
      if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1);
      else return;
    }
    if (fp.includes('node_modules') || fp.includes('.git/')) return;
    if (!pending[fp]) pending[fp] = { added: 0, removed: 0 };
    pending[fp].added += added;
    pending[fp].removed += removed;
  };

  // Parse unified diff (apply_patch format)
  const parsePatch = (patchText) => {
    if (!patchText) return;
    const lines = patchText.split('\n');
    let currentFile = null, added = 0, removed = 0;
    for (const line of lines) {
      const updateMatch = line.match(/^\*\*\* (?:Update File|Add File|Create File):\s*(.+)/);
      if (updateMatch) {
        if (currentFile) trackFile(currentFile, added, removed);
        currentFile = updateMatch[1].trim(); added = 0; removed = 0; continue;
      }
      const diffAMatch = line.match(/^--- a\/(.+)/);
      if (diffAMatch && !line.startsWith('--- a/dev/null')) {
        if (currentFile) trackFile(currentFile, added, removed);
        currentFile = diffAMatch[1].trim(); added = 0; removed = 0; continue;
      }
      if (line.startsWith('+') && !line.startsWith('+++')) added++;
      if (line.startsWith('-') && !line.startsWith('---')) removed++;
    }
    if (currentFile) trackFile(currentFile, added, removed);
  };

  const name = toolData.toolName;
  const args = toolData.args || {};

  if (name.includes('apply_patch')) {
    parsePatch(args.patch || args.input || args.content || '');
  } else if (name.includes('write_file') || name.includes('create_file')) {
    trackFile(args.file_path || args.path || '', countLines(args.content || ''), 0);
  }

  fs.writeFileSync(pendingPath, JSON.stringify(pending));
" 2>/dev/null || log_err "failed to update pending file"

log "updated pending file"
exit 0
