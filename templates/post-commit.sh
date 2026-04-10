#!/bin/bash
# Gitprint — Git Post-Commit Hook
# Fires after every git commit. Reads the active AI session transcript,
# computes DELTA stats since last commit, and writes a git note to HEAD.
# This gives per-commit AI attribution without waiting for session close.

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:post-commit] $*" >&2; }
log_err() { echo "[gitprint:post-commit] ERROR: $*" >&2; }

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
ACTIVE_FILE="$GIT_DIR/gitprint-active.json"
CHECKPOINT_FILE="$GIT_DIR/gitprint-checkpoint.json"

# ─── Check for active AI session ───
if [ ! -f "$ACTIVE_FILE" ]; then
  log "no active session marker — manual commit, skipping"
  exit 0
fi

# Read active session info
ACTIVE=$(cat "$ACTIVE_FILE")
TRANSCRIPT_PATH=$(echo "$ACTIVE" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).transcript_path||''); }
    catch(e) { console.log(''); }
  });
")
SESSION_ID=$(echo "$ACTIVE" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).session_id||'unknown'); }
    catch(e) { console.log('unknown'); }
  });
")

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  log "transcript not found: $TRANSCRIPT_PATH"
  exit 0
fi

# ─── Read checkpoint (last processed line) ───
LAST_LINE=0
if [ -f "$CHECKPOINT_FILE" ]; then
  LAST_LINE=$(node -e "
    try {
      const cp = JSON.parse(require('fs').readFileSync('$CHECKPOINT_FILE', 'utf8'));
      // Only use checkpoint if it's for the same transcript
      if (cp.transcript_path === '$TRANSCRIPT_PATH') {
        console.log(cp.last_line || 0);
      } else {
        console.log(0);
      }
    } catch(e) { console.log(0); }
  ")
fi
log "checkpoint: last_line=$LAST_LINE"

# ─── Parse transcript DELTA (from LAST_LINE to end) ───
STATS=$(node -e "
  const fs = require('fs');
  const allLines = fs.readFileSync('$TRANSCRIPT_PATH', 'utf8')
    .split('\n')
    .filter(Boolean);

  const lastLine = $LAST_LINE;
  const deltaLines = allLines.slice(lastLine);
  const totalLineCount = allLines.length;

  if (deltaLines.length === 0) {
    // No new lines since last commit
    console.log(JSON.stringify({ empty: true, totalLineCount }));
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
  const trackFile = (fp, added, removed, newStrContent = '') => {
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
    if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0, _newStrContent: '' };
    fileLineStats[fp].added += added;
    fileLineStats[fp].removed += removed;
    fileLineStats[fp]._newStrContent += '\n' + newStrContent;
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
            trackFile(fp, countLines(newStr), countLines(oldStr), newStr);
          }

          if (/^MultiEdit$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            for (const edit of (input.edits || [])) {
              const ns = edit.new_str || edit.new_string || '';
              trackFile(fp, countLines(ns), countLines(edit.old_str || edit.old_string || ''), ns);
            }
          }

          if (/^(Write|Create|file_write|create_file|write)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            const content = input.content || input.file_text || '';
            trackFile(fp, countLines(content), 0, content);
          }
        }
      }
    } catch (e) {}
  });

  // ─── Committed diff intersection (replace proposed line counts with actual committed lines) ───
  const { execSync: execSyncDiff } = require('child_process');
  const intersectedStats = {};

  for (const [fp, stat] of Object.entries(fileLineStats)) {
    try {
      const diffOut = execSyncDiff('git diff HEAD~1..HEAD -- "' + fp + '" 2>/dev/null', { encoding: 'utf8' });
      const committedLines = new Set(
        diffOut.split('\n')
          .filter(l => l.startsWith('+') && !l.startsWith('+++'))
          .map(l => l.slice(1).trim())
          .filter(l => l.length > 1)
      );
      const aiProposed = (stat._newStrContent || '').split('\n')
        .map(l => l.trim())
        .filter(l => l.length > 1);
      const matched = aiProposed.filter(l => committedLines.has(l)).length;
      intersectedStats[fp] = { ai_lines_added: matched, ai_lines_removed: 0 };
    } catch {
      // fallback: use original counts if diff fails (e.g. first commit)
      intersectedStats[fp] = { ai_lines_added: stat.added || 0, ai_lines_removed: stat.removed || 0 };
    }
  }

  const aiFiles = Object.entries(intersectedStats).map(([file, s]) => ({
    file, ai_lines_added: s.ai_lines_added, ai_lines_removed: s.ai_lines_removed
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
    ai_files: aiFiles,
    totalLineCount
  }));
")

if [ -z "$STATS" ] || [ "$STATS" = "{}" ]; then
  log "empty stats from transcript delta"
  exit 0
fi

# Check if delta was empty (no new transcript lines)
IS_EMPTY=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { const s=JSON.parse(d); console.log(s.empty ? 'true' : 'false'); }
    catch(e) { console.log('false'); }
  });
")

# Get totalLineCount for checkpoint update
TOTAL_LINE_COUNT=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).totalLineCount || 0); }
    catch(e) { console.log(0); }
  });
")

if [ "$IS_EMPTY" = "true" ]; then
  log "no new transcript lines since last commit"
  # Still update checkpoint in case transcript grew
  node -e "
    require('fs').writeFileSync('$CHECKPOINT_FILE', JSON.stringify({
      transcript_path: '$TRANSCRIPT_PATH',
      session_id: '$SESSION_ID',
      last_line: $TOTAL_LINE_COUNT,
      updated: new Date().toISOString()
    }));
  "
  exit 0
fi

# Check if there are any AI file edits in this delta
HAS_AI_FILES=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { const s=JSON.parse(d); console.log((s.ai_files||[]).length > 0 ? 'true' : 'false'); }
    catch(e) { console.log('false'); }
  });
")

# ─── Get HEAD SHA ───
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  log_err "no HEAD commit"
  exit 0
fi

# ─── Build note data ───
MERGED=$(node -e "
  const existing = process.argv[1] || '{}';
  const newStats = JSON.parse(process.argv[2]);

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

  // Add session (skip ai_files and totalLineCount from session entry)
  const session = { ...newStats };
  delete session.ai_files;
  delete session.totalLineCount;
  delete session.empty;
  const exists = data.sessions.find(s => s.session_id === session.session_id);
  if (!exists) data.sessions.push(session);
  else Object.assign(exists, session); // update with latest delta

  console.log(JSON.stringify(data));
" "$(git notes --ref=gitprint show "$HEAD_SHA" 2>/dev/null || echo '{}')" "$STATS")

# ─── Write git note ───
NOTE_ERR=$(echo "$MERGED" | git notes --ref=gitprint add -f --file=- "$HEAD_SHA" 2>&1) || log_err "git notes write failed: $NOTE_ERR"
log "note written to $HEAD_SHA (delta from line $LAST_LINE to $TOTAL_LINE_COUNT)"

# ─── Update checkpoint ───
node -e "
  require('fs').writeFileSync('$CHECKPOINT_FILE', JSON.stringify({
    transcript_path: '$TRANSCRIPT_PATH',
    session_id: '$SESSION_ID',
    last_line: $TOTAL_LINE_COUNT,
    updated: new Date().toISOString()
  }));
"
log "checkpoint updated: last_line=$TOTAL_LINE_COUNT"

# ─── Push notes (best-effort, silent fail if offline) ───
git push origin refs/notes/gitprint 2>/dev/null &
disown 2>/dev/null
log "push triggered in background"

exit 0
