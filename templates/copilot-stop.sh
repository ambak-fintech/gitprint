#!/bin/bash
# Gitprint — Copilot CLI sessionEnd Hook
# Fires when a Copilot CLI session ends
# Discovers session data from ~/.copilot/session-state/
# Parses events.jsonl for tokens, models, and per-file AI line counts
# Merges with incremental data from copilot-post-tool.sh
# Stores data as a Git Note on HEAD (no files to commit/cleanup)

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:copilot] $*" >&2; }
log_err() { echo "[gitprint:copilot] ERROR: $*" >&2; }

INPUT=$(cat)

# ─── Extract cwd from stdin ───
HOOK_CWD=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).cwd || ''); }
    catch(e) { console.log(''); }
  });
")

if [ -z "$HOOK_CWD" ]; then
  HOOK_CWD=$(pwd)
  log "no cwd in input, using pwd: $HOOK_CWD"
fi

# ─── Session discovery ───
# Walk ~/.copilot/session-state/ directories, match cwd via workspace.yaml
SESSION_STATE_DIR="$HOME/.copilot/session-state"

if [ ! -d "$SESSION_STATE_DIR" ]; then
  log "copilot session-state directory not found: $SESSION_STATE_DIR"
  exit 0
fi

# Find matching session by cwd in workspace.yaml
SESSION_DATA=$(node -e "
  const fs = require('fs');
  const path = require('path');

  const sessionStateDir = '$SESSION_STATE_DIR';
  const hookCwd = '$HOOK_CWD';

  let bestDir = null;
  let bestMtime = 0;

  try {
    const dirs = fs.readdirSync(sessionStateDir);
    for (const dir of dirs) {
      const fullDir = path.join(sessionStateDir, dir);
      const stat = fs.statSync(fullDir);
      if (!stat.isDirectory()) continue;

      // Check workspace.yaml for cwd match
      const wsPath = path.join(fullDir, 'workspace.yaml');
      try {
        const wsContent = fs.readFileSync(wsPath, 'utf8');
        const cwdMatch = wsContent.match(/cwd:\s*(.+)/);
        if (!cwdMatch) continue;

        const sessionCwd = cwdMatch[1].trim().replace(/[\"']/g, '');
        if (sessionCwd !== hookCwd) continue;

        // Check events.jsonl exists and get mtime
        const eventsPath = path.join(fullDir, 'events.jsonl');
        try {
          const eventsStat = fs.statSync(eventsPath);
          if (eventsStat.mtimeMs > bestMtime) {
            bestMtime = eventsStat.mtimeMs;
            bestDir = fullDir;
          }
        } catch(e) { /* no events.jsonl */ }
      } catch(e) { /* no workspace.yaml or unreadable */ }
    }
  } catch(e) {
    console.error('[gitprint:copilot] ERROR: failed to scan session-state: ' + e.message);
  }

  if (bestDir) {
    console.log(JSON.stringify({
      dir: bestDir,
      session_id: path.basename(bestDir),
      events_path: path.join(bestDir, 'events.jsonl')
    }));
  } else {
    console.log(JSON.stringify({ dir: null }));
  }
")

SESSION_DIR=$(echo "$SESSION_DATA" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).dir || ''); }
    catch(e) { console.log(''); }
  });
")

if [ -z "$SESSION_DIR" ]; then
  log "no matching copilot session found for cwd: $HOOK_CWD"
  exit 0
fi

SESSION_ID=$(echo "$SESSION_DATA" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).session_id || 'unknown'); }
    catch(e) { console.log('unknown'); }
  });
")

EVENTS_PATH=$(echo "$SESSION_DATA" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).events_path || ''); }
    catch(e) { console.log(''); }
  });
")

log "found session: $SESSION_ID"
log "events: $EVENTS_PATH"

# ─── Must be in a git repo ───
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
if [ -z "$GIT_DIR" ]; then
  log_err "not in a git repo"
  exit 0
fi

# ─── Read pending file data from postToolUse hook ───
PENDING_FILE="$GIT_DIR/gitprint-copilot-pending.json"
PENDING_DATA="{}"
if [ -f "$PENDING_FILE" ]; then
  PENDING_DATA=$(cat "$PENDING_FILE")
  rm -f "$PENDING_FILE"
  log "read and removed pending file"
fi

# ─── Parse events.jsonl for tokens, models, and file edits ───
STATS=$(node -e "
  const fs = require('fs');
  const eventsPath = '$EVENTS_PATH';
  const pendingData = $PENDING_DATA;

  let inputTokens = 0, outputTokens = 0, cacheCreation = 0, cacheRead = 0, turns = 0;
  const models = {};
  const fileLineStats = {};

  const countLines = (str) => {
    if (!str) return 0;
    const s = String(str);
    return s.length === 0 ? 0 : s.split('\n').length;
  };

  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\.\//, '');
    const cwd = '$HOOK_CWD' || process.cwd();
    if (fp.startsWith(cwd + '/')) fp = fp.slice(cwd.length + 1);
    if (fp.includes('node_modules')) return;
    if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
    fileLineStats[fp].added += added;
    fileLineStats[fp].removed += removed;
  };

  // Parse events.jsonl
  try {
    const lines = fs.readFileSync(eventsPath, 'utf8').split('\n').filter(Boolean);

    for (const line of lines) {
      try {
        const entry = JSON.parse(line);

        // Token tracking from assistant.message events
        if ((entry.type === 'assistant.message' || entry.type === 'assistant') && entry.usage) {
          const u = entry.usage;
          // Try both Copilot field names and Claude-style names
          const inp = u.prompt_tokens || u.input_tokens || 0;
          const out = u.completion_tokens || u.output_tokens || 0;
          const cc = u.cache_creation_input_tokens || 0;
          const cr = u.cache_read_input_tokens || 0;

          inputTokens += inp;
          outputTokens += out;
          cacheCreation += cc;
          cacheRead += cr;
          turns++;

          const model = entry.model || u.model || 'unknown';
          if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, turns: 0 };
          models[model].input_tokens += inp + cc + cr;
          models[model].output_tokens += out;
          models[model].turns++;
        }

        // Also check message.usage (nested)
        if (entry.message?.usage) {
          const u = entry.message.usage;
          const inp = u.prompt_tokens || u.input_tokens || 0;
          const out = u.completion_tokens || u.output_tokens || 0;
          const cc = u.cache_creation_input_tokens || 0;
          const cr = u.cache_read_input_tokens || 0;

          // Only count if not already counted above
          if (entry.type !== 'assistant.message' && entry.type !== 'assistant') {
            inputTokens += inp;
            outputTokens += out;
            cacheCreation += cc;
            cacheRead += cr;
            turns++;

            const model = entry.model || entry.message?.model || 'unknown';
            if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, turns: 0 };
            models[model].input_tokens += inp + cc + cr;
            models[model].output_tokens += out;
            models[model].turns++;
          }
        }

        // Token tracking from session.updated events
        if (entry.type === 'session.updated' && entry.usage) {
          const u = entry.usage;
          const inp = u.prompt_tokens || u.input_tokens || 0;
          const out = u.completion_tokens || u.output_tokens || 0;
          const cc = u.cache_creation_input_tokens || 0;
          const cr = u.cache_read_input_tokens || 0;

          inputTokens += inp;
          outputTokens += out;
          cacheCreation += cc;
          cacheRead += cr;

          const model = entry.model || 'unknown';
          if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, turns: 0 };
          models[model].input_tokens += inp + cc + cr;
          models[model].output_tokens += out;
        }

        // File edit tracking from tool.execution_complete events (fallback)
        if (entry.type === 'tool.execution_complete') {
          const toolName = entry.toolName || entry.tool_name || '';
          let args = {};
          try {
            args = typeof entry.toolArgs === 'string' ? JSON.parse(entry.toolArgs) : (entry.toolArgs || {});
          } catch(e) {
            try {
              args = typeof entry.tool_args === 'string' ? JSON.parse(entry.tool_args) : (entry.tool_args || {});
            } catch(e2) { args = {}; }
          }

          if (toolName === 'replace_string_in_file') {
            const fp = args.path || args.file_path || '';
            trackFile(fp, countLines(args.new_string || args.new_str || ''), countLines(args.old_string || args.old_str || ''));
          }

          if (toolName === 'multi_replace_string_in_file') {
            const fp = args.path || args.file_path || '';
            for (const edit of (args.edits || args.replacements || [])) {
              trackFile(fp, countLines(edit.new_string || edit.new_str || ''), countLines(edit.old_string || edit.old_str || ''));
            }
          }

          if (toolName === 'create_file') {
            const fp = args.path || args.file_path || '';
            trackFile(fp, countLines(args.content || ''), 0);
          }
        }
      } catch (e) {}
    }
  } catch(e) {
    // events.jsonl unreadable — continue with pending data only
  }

  // If pending file had data, use it as authoritative for file edits
  const hasPendingData = Object.keys(pendingData).length > 0;
  let aiFiles;

  if (hasPendingData) {
    // Pending data from postToolUse is authoritative
    aiFiles = Object.entries(pendingData).map(([file, s]) => ({
      file, ai_lines_added: s.added || 0, ai_lines_removed: s.removed || 0
    }));
  } else {
    // Fall back to events.jsonl file tracking
    aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
      file, ai_lines_added: s.added, ai_lines_removed: s.removed
    }));
  }

  // ─── Cost estimation ($ per million tokens) ───
  const pricing = {
    'opus':   { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
    'sonnet': { input: 3,  output: 15, cache_read: 0.30, cache_creation: 3.75 },
    'haiku':  { input: 1,  output: 5,  cache_read: 0.10, cache_creation: 1.25 },
    'gpt-4o': { input: 2.50, output: 10, cache_read: 1.25, cache_creation: 2.50 },
    'gpt-4o-mini': { input: 0.15, output: 0.60, cache_read: 0.075, cache_creation: 0.15 },
    'o1':     { input: 15, output: 60, cache_read: 7.50, cache_creation: 15 },
    'o3':     { input: 10, output: 40, cache_read: 5, cache_creation: 10 },
    'o3-mini': { input: 1.10, output: 4.40, cache_read: 0.55, cache_creation: 1.10 },
    'gemini-2.5-pro': { input: 1.25, output: 10, cache_read: 0.315, cache_creation: 1.25 },
    'gemini-2.5-flash': { input: 0.15, output: 0.60, cache_read: 0.0375, cache_creation: 0.15 },
  };

  const matchPricing = (modelName) => {
    const ml = modelName.toLowerCase();
    // Exact prefix matches first
    for (const [key, rates] of Object.entries(pricing)) {
      if (ml.includes(key)) return rates;
    }
    // Fallback family matches
    if (ml.includes('opus')) return pricing.opus;
    if (ml.includes('sonnet')) return pricing.sonnet;
    if (ml.includes('haiku')) return pricing.haiku;
    if (ml.includes('gpt-4o-mini')) return pricing['gpt-4o-mini'];
    if (ml.includes('gpt-4o') || ml.includes('gpt-4')) return pricing['gpt-4o'];
    if (ml.includes('o3-mini')) return pricing['o3-mini'];
    if (ml.includes('o3')) return pricing.o3;
    if (ml.includes('o1')) return pricing.o1;
    if (ml.includes('gemini') && ml.includes('flash')) return pricing['gemini-2.5-flash'];
    if (ml.includes('gemini')) return pricing['gemini-2.5-pro'];
    return pricing.sonnet; // default fallback
  };

  let estimatedCost = 0;
  for (const [model, info] of Object.entries(models)) {
    const p = matchPricing(model);
    estimatedCost += (info.input_tokens / 1e6) * p.input;
    estimatedCost += (info.output_tokens / 1e6) * p.output;
  }
  const dominantModel = Object.keys(models).sort((a, b) =>
    (models[b].input_tokens + models[b].output_tokens) - (models[a].input_tokens + models[a].output_tokens)
  )[0] || '';
  const dp = matchPricing(dominantModel);
  estimatedCost += (cacheCreation / 1e6) * dp.cache_creation;
  estimatedCost += (cacheRead / 1e6) * dp.cache_read;

  console.log(JSON.stringify({
    session_id: '$SESSION_ID',
    tool: 'copilot',
    timestamp: new Date().toISOString(),
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_creation_tokens: cacheCreation,
    cache_read_tokens: cacheRead,
    estimated_cost: Math.round(estimatedCost * 10000) / 10000,
    turns,
    models,
    ai_files: aiFiles
  }));
")

if [ -z "$STATS" ] || [ "$STATS" = "{}" ]; then
  log "empty stats from session"
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
