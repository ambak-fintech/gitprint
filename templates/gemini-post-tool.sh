#!/bin/bash
# Gitprint — Gemini CLI AfterTool Hook
# Fires after each tool execution in a Gemini CLI session.
# Tracks replace/write_file file edits in .git/gitprint-gemini-pending.json
# Data is consumed by gemini-stop.sh when the session ends.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:gemini:post-tool] $*" >&2; }
log_err() { echo "[gitprint:gemini:post-tool] ERROR: $*" >&2; }

INPUT=$(cat)

# ─── Parse tool info ───
TOOL_DATA=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      // AfterTool provides: tool_name (or toolName/name), tool_input (or toolInput/input/args)
      const toolName = (j.tool_name || j.toolName || j.name || j.tool || '').toLowerCase();

      // Gemini file-editing tools
      const tracked = ['replace', 'write_file', 'create_file', 'edit', 'str_replace', 'write'];
      if (!tracked.some(t => toolName.includes(t))) {
        console.log(JSON.stringify({ skip: true }));
        return;
      }

      const args = j.tool_input || j.toolInput || j.input || j.args || j.arguments || {};
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
PENDING_FILE="$GIT_DIR/gitprint-gemini-pending.json"

node -e "
  const fs = require('fs');
  const path = require('path');
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
    fp = fp.replace(/^\.\//, '');
    if (fp.startsWith('/')) {
      if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1);
      else return;
    } else {
      const abs = path.resolve(toolData.cwd || process.cwd(), fp);
      if (abs.startsWith(repoRoot + '/')) fp = abs.slice(repoRoot.length + 1);
    }
    if (fp.includes('node_modules') || fp.includes('.git/')) return;
    if (!pending[fp]) pending[fp] = { added: 0, removed: 0 };
    pending[fp].added += added;
    pending[fp].removed += removed;
  };

  const name = toolData.toolName;
  const args = toolData.args || {};

  // replace / str_replace / edit
  if (name.includes('replace') || name.includes('edit')) {
    const fp = args.file_path || args.path || args.filePath || '';
    const oldStr = args.old_string || args.old_str || args.oldString || '';
    const newStr = args.new_string || args.new_str || args.newString || args.replacement || '';
    trackFile(fp, countLines(newStr), countLines(oldStr));
  }

  // write_file / create_file / write
  if (name.includes('write') || name.includes('create')) {
    const fp = args.file_path || args.path || args.filePath || '';
    trackFile(fp, countLines(args.content || args.file_text || ''), 0);
  }

  fs.writeFileSync(pendingPath, JSON.stringify(pending));
" 2>/dev/null || log_err "failed to update pending file"

log "updated pending file"
exit 0
