#!/bin/bash
# Gitprint — Cursor Stop Hook
# Fires when a Cursor session ends (sessionEnd hook)
# Parses transcript for tokens, models, and per-file AI line counts
# Stores data as a Git Note on HEAD (no files to commit/cleanup)

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:cursor] $*" >&2; }
log_err() { echo "[gitprint:cursor] ERROR: $*" >&2; }

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
    try {
      const j = JSON.parse(d);
      console.log(j.conversation_id || j.session_id || 'unknown');
    } catch(e) { console.log('unknown'); }
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

# ─── Parse transcript ───
STATS=$(node -e "
  const fs = require('fs');
  const lines = fs.readFileSync('$TRANSCRIPT_PATH', 'utf8')
    .split('\n')
    .filter(Boolean);

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
    fp = fp.replace(/^\\.\//, '');
    const cwd = process.cwd();
    if (fp.startsWith(cwd + '/')) fp = fp.slice(cwd.length + 1);
    if (fp.includes('.ai-stats') || fp.includes('node_modules')) return;
    if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
    fileLineStats[fp].added += added;
    fileLineStats[fp].removed += removed;
  };

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      if (entry.isSidechain || entry.isApiErrorMessage) continue;

      // Token tracking
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
        turns++;

        const model = entry.model || entry.message?.model || 'unknown';
        if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, turns: 0 };
        models[model].input_tokens += inp + cc + cr;
        models[model].output_tokens += out;
        models[model].turns++;
      }

      // File + line tracking from tool_use blocks
      if (entry.type === 'assistant' && entry.message?.content) {
        for (const block of entry.message.content) {
          if (block.type !== 'tool_use') continue;
          const name = block.name || '';
          const input = block.input || {};

          // Edit / str_replace
          if (/^(Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            const oldStr = input.old_str || input.old_string || input.oldStr || '';
            const newStr = input.new_str || input.new_string || input.newStr || input.replacement || '';
            trackFile(fp, countLines(newStr), countLines(oldStr));
          }

          // MultiEdit
          if (/^MultiEdit$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            for (const edit of (input.edits || [])) {
              trackFile(fp, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
            }
          }

          // Write / Create
          if (/^(Write|Create|file_write|create_file|write)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            trackFile(fp, countLines(input.content || input.file_text || ''), 0);
          }
        }
      }
    } catch (e) {}
  }

  const aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
    file, ai_lines_added: s.added, ai_lines_removed: s.removed
  }));

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
    tool: 'cursor',
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
  log "empty stats from transcript"
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
