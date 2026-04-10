#!/bin/bash
# Gitprint — Stop Hook (Claude Code)
# Fires when a Claude Code session ends.
# With the post-commit hook handling per-commit attribution,
# this hook only processes the REMAINING delta (uncommitted AI work).
# Falls back to full parse if no checkpoint exists (backward compat).

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint] $*" >&2; }
log_err() { echo "[gitprint] ERROR: $*" >&2; }

INPUT=$(cat)

TRANSCRIPT_PATH=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).transcript_path); }
    catch(e) { console.log(''); }
  });
")

SESSION_ID=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).session_id); }
    catch(e) { console.log('unknown'); }
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
CHECKPOINT_FILE="$GIT_DIR/gitprint-checkpoint.json"
ACTIVE_FILE="$GIT_DIR/gitprint-active.json"

# ─── Read checkpoint to determine start line ───
LAST_LINE=0
if [ -f "$CHECKPOINT_FILE" ]; then
  LAST_LINE=$(node -e "
    try {
      const cp = JSON.parse(require('fs').readFileSync('$CHECKPOINT_FILE', 'utf8'));
      if (cp.transcript_path === '$TRANSCRIPT_PATH') {
        console.log(cp.last_line || 0);
      } else {
        console.log(0);
      }
    } catch(e) { console.log(0); }
  ")
fi
log "stop hook: checkpoint last_line=$LAST_LINE"

# ─── Parse transcript (from checkpoint to end = remaining delta) ───
STATS=$(node -e "
  const fs = require('fs');
  const allLines = fs.readFileSync('$TRANSCRIPT_PATH', 'utf8')
    .split('\n')
    .filter(Boolean);

  const lastLine = $LAST_LINE;
  const deltaLines = allLines.slice(lastLine);

  if (deltaLines.length === 0) {
    console.log(JSON.stringify({ empty: true }));
    process.exit(0);
  }

  let inputTokens = 0, outputTokens = 0, cacheCreation = 0, cacheRead = 0, turns = 0, apiCalls = 0;
  const models = {};
  const fileLineStats = {};

  const countLines = (str) => {
    if (!str) return 0;
    const s = String(str);
    return s.length === 0 ? 0 : s.split('\n').length;
  };

  const repoRoot = (() => { try { return require('child_process').execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim(); } catch { return process.cwd(); } })();
  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\\.\//, '');
    if (fp.startsWith('/')) {
      if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1);
      else return;
    } else {
      const abs = require('path').resolve(process.cwd(), fp);
      if (abs.startsWith(repoRoot + '/')) fp = abs.slice(repoRoot.length + 1);
    }
    if (fp.includes('.ai-stats') || fp.includes('node_modules')) return;
    if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
    fileLineStats[fp].added += added;
    fileLineStats[fp].removed += removed;
  };

  // Pre-pass: find last index per message.id to avoid streaming duplicate token counts
  const lastIndexById = {};
  deltaLines.forEach((line, idx) => {
    try {
      const e = JSON.parse(line);
      if (e.type === 'assistant' && e.message?.id) lastIndexById[e.message.id] = idx;
    } catch {}
  });

  deltaLines.forEach((line, idx) => {
    try {
      const entry = JSON.parse(line);
      if (entry.isSidechain || entry.isApiErrorMessage) return;

      if (entry.type === 'human') turns++;

      if (entry.type === 'assistant' && entry.message?.id) {
        if (idx !== lastIndexById[entry.message.id]) return; // skip partial streaming chunk
      }

      if (entry.type === 'assistant' && entry.message?.usage) {
        const u = entry.message.usage;
        const inp = u.input_tokens || 0;
        const out = u.output_tokens || 0;
        const cc = u.cache_creation_input_tokens || 0;
        const cr = u.cache_read_input_tokens || 0;

        inputTokens += inp;
        outputTokens += out;
        cacheCreation += cc;
        cacheRead += cr;
        apiCalls++;

        const model = entry.model || entry.message?.model || 'unknown';
        if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
        models[model].input_tokens += inp + cc + cr;
        models[model].output_tokens += out;
        models[model].api_calls++;
      }

      if (entry.type === 'assistant' && entry.message?.content) {
        for (const block of entry.message.content) {
          if (block.type !== 'tool_use') continue;
          const name = block.name || '';
          const input = block.input || {};

          if (/^(Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            const oldStr = input.old_str || input.old_string || input.oldStr || '';
            const newStr = input.new_str || input.new_string || input.newStr || input.replacement || '';
            trackFile(fp, countLines(newStr), countLines(oldStr));
          }

          if (/^MultiEdit$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            for (const edit of (input.edits || [])) {
              trackFile(fp, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
            }
          }

          if (/^(Write|Create|file_write|create_file|write)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            trackFile(fp, countLines(input.content || input.file_text || ''), 0);
          }
        }
      }
    } catch (e) {}
  });

  const aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
    file, ai_lines_added: s.added, ai_lines_removed: s.removed
  }));

  // ─── Cost estimation ───
  const pricing = {
    'opus':   { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
    'sonnet': { input: 3,  output: 15, cache_read: 0.30, cache_creation: 3.75 },
    'haiku':  { input: 1,  output: 5,  cache_read: 0.10, cache_creation: 1.25 },
  };
  const matchPricing = (modelName) => {
    const ml = modelName.toLowerCase();
    if (ml.includes('opus')) return pricing.opus;
    if (ml.includes('sonnet')) return pricing.sonnet;
    if (ml.includes('haiku')) return pricing.haiku;
    return pricing.sonnet;
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
    tool: 'claude-code',
    timestamp: new Date().toISOString(),
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_creation_tokens: cacheCreation,
    cache_read_tokens: cacheRead,
    estimated_cost: Math.round(estimatedCost * 10000) / 10000,
    turns,
    api_calls: apiCalls,
    models,
    ai_files: aiFiles
  }));
")

if [ -z "$STATS" ] || [ "$STATS" = "{}" ]; then
  log "empty stats from transcript"
  # Clean up state files
  rm -f "$CHECKPOINT_FILE" "$ACTIVE_FILE" 2>/dev/null
  exit 0
fi

# Check if delta was empty (no new lines since last commit)
IS_EMPTY=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { const s=JSON.parse(d); console.log(s.empty ? 'true' : 'false'); }
    catch(e) { console.log('false'); }
  });
")

if [ "$IS_EMPTY" = "true" ]; then
  log "no remaining delta — all work already captured by post-commit hooks"
  # Clean up state files
  rm -f "$CHECKPOINT_FILE" "$ACTIVE_FILE" 2>/dev/null
  exit 0
fi

# Check if there are any AI file edits OR token usage in this delta
HAS_CONTENT=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const s=JSON.parse(d);
      const hasFiles = (s.ai_files||[]).length > 0;
      const hasTokens = (s.input_tokens||0) + (s.output_tokens||0) > 0;
      console.log((hasFiles || hasTokens) ? 'true' : 'false');
    } catch(e) { console.log('false'); }
  });
")

if [ "$HAS_CONTENT" != "true" ]; then
  log "no AI content in remaining delta"
  rm -f "$CHECKPOINT_FILE" "$ACTIVE_FILE" 2>/dev/null
  exit 0
fi

# ─── Get current HEAD SHA ───
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  log_err "not in a git repo or no commits"
  exit 0
fi

# ─── Read existing note (if any) and merge ───
MERGED=$(node -e "
  const existing = process.argv[1] || '{}';
  const newStats = $STATS;

  let data;
  try { data = JSON.parse(existing); } catch(e) { data = {}; }
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

  // Add session
  const session = { ...newStats };
  delete session.ai_files;
  const exists = data.sessions.find(s => s.session_id === session.session_id);
  if (!exists) data.sessions.push(session);
  else Object.assign(exists, session);

  console.log(JSON.stringify(data));
" "$(git notes --ref=gitprint show "$HEAD_SHA" 2>/dev/null || echo '{}')")

# ─── Write git note to HEAD (remaining delta goes to latest commit) ───
NOTE_ERR=$(echo "$MERGED" | git notes --ref=gitprint add -f --file=- "$HEAD_SHA" 2>&1) || log_err "git notes write failed: $NOTE_ERR"
log "note written to $HEAD_SHA (remaining delta)"

# ─── Clean up state files ───
rm -f "$CHECKPOINT_FILE" "$ACTIVE_FILE" 2>/dev/null
log "cleaned up checkpoint and active session files"

# ─── Push notes ───
git push origin refs/notes/gitprint 2>/dev/null &
disown 2>/dev/null
log "push triggered in background"

exit 0
