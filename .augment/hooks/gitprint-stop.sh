#!/bin/bash
# Gitprint — Augment Code Stop Hook
# Fires when an Augment Code session ends
# Reads file edit data accumulated by augment-post-tool.sh
# NOTE: Augment Code does not provide token usage data
# Stores data as a Git Note on HEAD (no files to commit/cleanup)

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:augment] $*" >&2; }
log_err() { echo "[gitprint:augment] ERROR: $*" >&2; }

INPUT=$(cat)

# ─── Extract session ID from stdin ───
SESSION_ID=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      console.log(j.conversation_id || j.session_id || j.agent_id || 'unknown');
    } catch(e) { console.log('unknown'); }
  });
")

log "session end for: $SESSION_ID"

# ─── Must be in a git repo ───
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
if [ -z "$GIT_DIR" ]; then
  log_err "not in a git repo"
  exit 0
fi

# ─── Read pending file data from PostToolUse hook ───
PENDING_FILE="$GIT_DIR/gitprint-augment-pending.json"
PENDING_DATA="{}"
if [ -f "$PENDING_FILE" ]; then
  PENDING_DATA=$(cat "$PENDING_FILE")
  rm -f "$PENDING_FILE"
  log "read and removed pending file"
else
  log "no pending file found — no file edits tracked"
fi

# ─── Build stats ───
STATS=$(node -e "
  const pendingData = $PENDING_DATA;

  const aiFiles = Object.entries(pendingData).map(([file, s]) => ({
    file, ai_lines_added: s.added || 0, ai_lines_removed: s.removed || 0
  }));

  // Augment Code does not provide token data
  console.log(JSON.stringify({
    session_id: '$SESSION_ID',
    tool: 'augment',
    timestamp: new Date().toISOString(),
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_tokens: 0,
    cache_read_tokens: 0,
    estimated_cost: 0,
    turns: 0,
    models: {},
    ai_files: aiFiles
  }));
")

if [ -z "$STATS" ] || [ "$STATS" = "{}" ]; then
  log "empty stats from session"
  exit 0
fi

# Check if there are any file edits — skip writing note if no data
HAS_FILES=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      console.log((j.ai_files || []).length > 0 ? 'yes' : 'no');
    } catch(e) { console.log('no'); }
  });
")

if [ "$HAS_FILES" = "no" ]; then
  log "no file edits tracked — skipping note"
  exit 0
fi

# ─── Get current HEAD SHA ───
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  log_err "not in a git repo or no commits"
  exit 0
fi

# ─── Read existing note (if any) and merge sessions ───
MERGED=$(node -e "
  const existing = process.argv[1] || '{}';
  const newStats = $STATS;

  let data;
  try {
    data = JSON.parse(existing);
  } catch(e) {
    data = {};
  }
  if (!data.sessions) data.sessions = [];
  if (!data.ai_files) data.ai_files = [];

  // Merge AI file stats
  const fileMap = {};
  for (const f of data.ai_files) {
    fileMap[f.file] = { ai_lines_added: f.ai_lines_added || 0, ai_lines_removed: f.ai_lines_removed || 0 };
  }
  for (const f of (newStats.ai_files || [])) {
    if (!fileMap[f.file]) fileMap[f.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
    fileMap[f.file].ai_lines_added += f.ai_lines_added || 0;
    fileMap[f.file].ai_lines_removed += f.ai_lines_removed || 0;
  }
  data.ai_files = Object.entries(fileMap).map(([file, s]) => ({
    file, ai_lines_added: s.ai_lines_added, ai_lines_removed: s.ai_lines_removed
  }));

  // Add session (skip ai_files from session entry)
  const session = { ...newStats };
  delete session.ai_files;
  const exists = data.sessions.find(s => s.session_id === session.session_id);
  if (!exists) data.sessions.push(session);

  console.log(JSON.stringify(data));
" "$(git notes --ref=gitprint show "$HEAD_SHA" 2>/dev/null || echo '{}')")

# ─── Write git note ───
NOTE_ERR=$(echo "$MERGED" | git notes --ref=gitprint add -f --file=- "$HEAD_SHA" 2>&1) || log_err "git notes write failed: $NOTE_ERR"
log "note written to $HEAD_SHA"

# ─── Push notes (best-effort, silent fail if offline) ───
git push origin refs/notes/gitprint 2>/dev/null &
disown 2>/dev/null
log "push triggered in background"

exit 0
