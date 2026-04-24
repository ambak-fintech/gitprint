#!/bin/bash
# Gitprint — Augment Code Stop Hook
# Fires when an Augment Code session ends
# Reads file edit data accumulated by augment-post-tool.sh
# NOTE: Augment Code does not provide token usage data
# Stores leftover data as a Git Note on HEAD, then best-effort reuses the
# shared post-commit uploader to push note data to the configured platform.

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

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_HELPER="$REPO_ROOT/.github/hooks/gitprint-state.js"
STATE_FILES=$(node - "$STATE_HELPER" "$REPO_ROOT" "$GIT_DIR" <<'NODEEOF'
const state = require(process.argv[2]);
const context = state.resolveRepoStateContext({ cwd: process.argv[3], gitDir: process.argv[4], env: process.env });
const paths = state.resolveToolStatePaths(context, 'augment');
process.stdout.write(`${paths.pendingFile}\n${paths.activeFile}\n${paths.checkpointFile}`);
NODEEOF
)

# ─── Read pending file data from PostToolUse hook ───
PENDING_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '1p')
ACTIVE_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '2p')
CHECKPOINT_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '3p')
PENDING_DATA="{}"
CHECKPOINT_DATA="{}"
if [ -f "$PENDING_FILE" ]; then
  PENDING_DATA=$(cat "$PENDING_FILE")
  log "read pending file"
else
  log "no pending file found — no file edits tracked"
fi
if [ -f "$CHECKPOINT_FILE" ]; then
  CHECKPOINT_DATA=$(cat "$CHECKPOINT_FILE")
fi

# ─── Build stats ───
STATS=$(node -e "
  const pendingData = $PENDING_DATA;
  const checkpointData = $CHECKPOINT_DATA;

  const deltaFromCheckpoint = (current, previous) => {
    const delta = {};
    const allFiles = new Set([
      ...Object.keys(current || {}),
      ...Object.keys(previous || {}),
    ]);

    for (const file of allFiles) {
      const cur = current[file] || { added: 0, removed: 0 };
      const prev = previous[file] || { added: 0, removed: 0 };
      const added = Math.max(0, (cur.added || 0) - (prev.added || 0));
      const removed = Math.max(0, (cur.removed || 0) - (prev.removed || 0));
      if (added > 0 || removed > 0) delta[file] = { added, removed };
    }

    return delta;
  };

  const leftoverData = deltaFromCheckpoint(pendingData, checkpointData.files || {});

  const aiFiles = Object.entries(leftoverData).map(([file, s]) => ({
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
    api_calls: 0,
    models: {},
    ai_files: aiFiles
  }));
")

if [ -z "$STATS" ] || [ "$STATS" = "{}" ]; then
  log "empty stats from session"
  rm -f "$PENDING_FILE" "$ACTIVE_FILE" "$CHECKPOINT_FILE" 2>/dev/null
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
  rm -f "$PENDING_FILE" "$ACTIVE_FILE" "$CHECKPOINT_FILE" 2>/dev/null
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

  const mergeSession = (target, source) => {
    target.tool = source.tool || target.tool;
    target.timestamp = source.timestamp || target.timestamp;
    target.input_tokens = (target.input_tokens || 0) + (source.input_tokens || 0);
    target.output_tokens = (target.output_tokens || 0) + (source.output_tokens || 0);
    target.cache_creation_tokens = (target.cache_creation_tokens || 0) + (source.cache_creation_tokens || 0);
    target.cache_read_tokens = (target.cache_read_tokens || 0) + (source.cache_read_tokens || 0);
    target.estimated_cost = (target.estimated_cost || 0) + (source.estimated_cost || 0);
    target.turns = (target.turns || 0) + (source.turns || 0);
    target.api_calls = (target.api_calls || 0) + (source.api_calls || 0);

    if (!target.models) target.models = {};
    for (const [model, info] of Object.entries(source.models || {})) {
      if (!target.models[model]) target.models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
      target.models[model].input_tokens += info.input_tokens || 0;
      target.models[model].output_tokens += info.output_tokens || 0;
      target.models[model].api_calls = (target.models[model].api_calls || 0) + (info.api_calls || 0);
    }
  };

  // Add session (skip ai_files from session entry)
  const session = { ...newStats };
  delete session.ai_files;
  const exists = data.sessions.find(s => s.session_id === session.session_id);
  if (!exists) data.sessions.push(session);
  else mergeSession(exists, session);

  console.log(JSON.stringify(data));
" "$(git notes --ref=gitprint show "$HEAD_SHA" 2>/dev/null || echo '{}')")

# ─── Write git note ───
NOTE_ERR=$(echo "$MERGED" | git notes --ref=gitprint add -f --file=- "$HEAD_SHA" 2>&1) || log_err "git notes write failed: $NOTE_ERR"
log "note written to $HEAD_SHA"

# ─── Clear Augment session state ───
rm -f "$PENDING_FILE" "$ACTIVE_FILE" "$CHECKPOINT_FILE" 2>/dev/null
log "cleared Augment pending state"

# ─── Push notes (best-effort, silent fail if offline) ───
git push origin refs/notes/gitprint </dev/null 2>/dev/null &
disown 2>/dev/null
log "push triggered in background"

# ─── Reuse shared post-commit uploader (best-effort) ───
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
POST_COMMIT_HOOK="$REPO_ROOT/.github/hooks/post-commit"
if [ -x "$POST_COMMIT_HOOK" ]; then
  "$POST_COMMIT_HOOK" </dev/null >/dev/null 2>&1 || log "post-commit uploader failed"
else
  log "post-commit uploader not installed"
fi

exit 0
