#!/bin/bash
# Gitprint — Windsurf Transcript Hook
# Fires via post_cascade_response_with_transcript after each Cascade response.
# Writes an active transcript marker so post-commit can attach Windsurf deltas
# to the next git commit.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:windsurf] $*" >&2; }

INPUT=$(cat)

TRANSCRIPT_PATH=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      console.log(j.transcript_path || j.tool_info?.transcript_path || '');
    } catch(e) { console.log(''); }
  });
")

SESSION_ID=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      console.log(j.trajectory_id || j.execution_id || j.session_id || 'unknown');
    } catch(e) { console.log('unknown'); }
  });
")

HOOK_CWD=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      console.log(j.cwd || '');
    } catch(e) { console.log(''); }
  });
")

if [ -z "$TRANSCRIPT_PATH" ]; then
  log "no transcript_path in input"
  exit 0
fi

if [ ! -f "$TRANSCRIPT_PATH" ]; then
  log "transcript not found: $TRANSCRIPT_PATH"
  exit 0
fi

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_HELPER="$REPO_ROOT/.github/hooks/gitprint-state.js"

node - "$STATE_HELPER" "$REPO_ROOT" "$GIT_DIR" "$TRANSCRIPT_PATH" "$SESSION_ID" "$HOOK_CWD" <<'NODEEOF'
const state = require(process.argv[2]);
const context = state.resolveRepoStateContext({ cwd: process.argv[3], gitDir: process.argv[4], env: process.env });
const activeFile = state.resolveToolStatePaths(context, 'windsurf').activeFile;
const [transcriptPath, sessionId, cwd] = process.argv.slice(5);

try {
  state.writeJsonAtomic(activeFile, {
    transcript_path: transcriptPath,
    session_id: sessionId || 'unknown',
    cwd: cwd || process.cwd(),
    updated: new Date().toISOString(),
  });
} catch {}
NODEEOF

log "updated active transcript marker"
exit 0
