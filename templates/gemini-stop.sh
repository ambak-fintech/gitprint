#!/bin/bash
# Gitprint — Gemini CLI Stop Hook
# Fires when a Gemini CLI / Antigravity session ends.
# With the post-commit hook handling committed attribution,
# this hook only processes the remaining delta since the last checkpoint.

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:gemini] $*" >&2; }
log_err() { echo "[gitprint:gemini] ERROR: $*" >&2; }

INPUT=$(cat)

TRANSCRIPT_PATH=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).transcript_path || ''); }
    catch(e) { console.log(''); }
  });
")

SESSION_ID=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const j = JSON.parse(d);
      console.log(j.session_id || j.conversation_id || 'unknown');
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

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_HELPER="$REPO_ROOT/.github/hooks/gitprint-state.js"
STATE_FILES=$(node - "$STATE_HELPER" "$REPO_ROOT" "$GIT_DIR" <<'NODEEOF'
const state = require(process.argv[2]);
const context = state.resolveRepoStateContext({ cwd: process.argv[3], gitDir: process.argv[4], env: process.env });
const paths = state.resolveToolStatePaths(context, 'gemini');
process.stdout.write(`${paths.checkpointFile}\n${paths.activeFile}`);
NODEEOF
)
CHECKPOINT_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '1p')
ACTIVE_FILE=$(printf '%s\n' "$STATE_FILES" | sed -n '2p')

write_checkpoint() {
  node - "$STATE_HELPER" "$CHECKPOINT_FILE" "$TRANSCRIPT_PATH" "$SESSION_ID" "$1" <<'NODEEOF'
const state = require(process.argv[2]);
const [filePath, transcriptPath, sessionId, lastLine] = process.argv.slice(3);

try {
  state.writeJsonAtomic(filePath, {
    transcript_path: transcriptPath,
    session_id: sessionId || 'unknown',
    last_line: Number(lastLine || 0),
    updated: new Date().toISOString(),
  });
} catch {}
NODEEOF
}

clear_active() {
  rm -f "$ACTIVE_FILE" 2>/dev/null
}

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

STATS=$(node -e "
  const fs = require('fs');
  const allLines = fs.readFileSync('$TRANSCRIPT_PATH', 'utf8').split('\n').filter(Boolean);
  const deltaLines = allLines.slice($LAST_LINE);

  if (deltaLines.length === 0) {
    console.log(JSON.stringify({ empty: true, transcript_line_count: allLines.length }));
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

  for (const line of deltaLines) {
    try {
      const entry = JSON.parse(line);
      if (entry.isSidechain || entry.isApiErrorMessage) continue;

      if (entry.type === 'human' || entry.type === 'user') turns++;

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

      if (entry.type === 'message_update' && entry.tokens) {
        const inp = entry.tokens.input || entry.tokens.input_tokens || 0;
        const out = entry.tokens.output || entry.tokens.output_tokens || 0;
        const cc = entry.tokens.cache_creation || entry.tokens.cache_creation_input_tokens || 0;
        const cr = entry.tokens.cache_read || entry.tokens.cache_read_input_tokens || 0;

        inputTokens += inp;
        outputTokens += out;
        cacheCreation += cc;
        cacheRead += cr;
        apiCalls++;

        const model = entry.model || 'unknown';
        if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
        models[model].input_tokens += inp + cc + cr;
        models[model].output_tokens += out;
        models[model].api_calls++;
      }

      if (entry.usage && !entry.message?.usage && entry.type !== 'message_update') {
        const u = entry.usage;
        const inp = u.input_tokens || u.prompt_tokens || 0;
        const out = u.output_tokens || u.completion_tokens || 0;
        const cc = u.cache_creation_input_tokens || 0;
        const cr = u.cache_read_input_tokens || 0;

        inputTokens += inp;
        outputTokens += out;
        cacheCreation += cc;
        cacheRead += cr;
        apiCalls++;

        const model = entry.model || 'unknown';
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

          if (/^(replace|Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
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

          if (/^(write_file|Write|Create|file_write|create_file|write)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            trackFile(fp, countLines(input.content || input.file_text || ''), 0);
          }
        }
      }

      if (entry.type === 'tool_use' || entry.type === 'tool_call') {
        const name = entry.name || entry.tool_name || '';
        const input = entry.input || entry.args || {};

        if (/^(replace|Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
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

        if (/^(write_file|Write|Create|file_write|create_file|write)$/i.test(name)) {
          const fp = input.file_path || input.path || input.filePath;
          trackFile(fp, countLines(input.content || input.file_text || ''), 0);
        }
      }
    } catch (e) {}
  }

  const aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
    file, ai_lines_added: s.added, ai_lines_removed: s.removed
  }));

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
    'gemini-2.0-flash': { input: 0.10, output: 0.40, cache_read: 0.025, cache_creation: 0.10 },
  };

  const matchPricing = (modelName) => {
    const ml = modelName.toLowerCase();
    for (const [key, rates] of Object.entries(pricing)) {
      if (ml.includes(key)) return rates;
    }
    if (ml.includes('opus')) return pricing.opus;
    if (ml.includes('sonnet')) return pricing.sonnet;
    if (ml.includes('haiku')) return pricing.haiku;
    if (ml.includes('gemini') && ml.includes('flash')) return pricing['gemini-2.5-flash'];
    if (ml.includes('gemini')) return pricing['gemini-2.5-pro'];
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
    tool: 'gemini',
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
    transcript_line_count: allLines.length
  }));
")

if [ -z "$STATS" ] || [ "$STATS" = "{}" ]; then
  log "empty stats from transcript"
  clear_active
  exit 0
fi

TOTAL_LINES=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { const s=JSON.parse(d); console.log(s.transcript_line_count || 0); }
    catch(e) { console.log(0); }
  });
")

IS_EMPTY=$(echo "$STATS" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { const s=JSON.parse(d); console.log(s.empty ? 'true' : 'false'); }
    catch(e) { console.log('false'); }
  });
")

if [ "$IS_EMPTY" = "true" ]; then
  log "no remaining delta — all work already captured by post-commit hooks"
  write_checkpoint "$TOTAL_LINES"
  clear_active
  exit 0
fi

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
  write_checkpoint "$TOTAL_LINES"
  clear_active
  exit 0
fi

HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  log_err "not in a git repo or no commits"
  exit 0
fi

MERGED=$(node -e "
  const existing = process.argv[1] || '{}';
  const newStats = $STATS;

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

  let data;
  try { data = JSON.parse(existing); } catch(e) { data = {}; }
  if (!data.sessions) data.sessions = [];
  if (!data.ai_files) data.ai_files = [];

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

  const session = { ...newStats };
  delete session.ai_files;
  delete session.transcript_line_count;
  const exists = data.sessions.find(s => s.session_id === session.session_id);
  if (!exists) data.sessions.push(session);
  else mergeSession(exists, session);

  console.log(JSON.stringify(data));
" "$(git notes --ref=gitprint show "$HEAD_SHA" 2>/dev/null || echo '{}')")

NOTE_ERR=$(echo "$MERGED" | git notes --ref=gitprint add -f --file=- "$HEAD_SHA" 2>&1) || log_err "git notes write failed: $NOTE_ERR"
log "note written to $HEAD_SHA (remaining delta)"

write_checkpoint "$TOTAL_LINES"
clear_active
log "updated checkpoint and cleared active session marker"

git push origin refs/notes/gitprint </dev/null 2>/dev/null &
disown 2>/dev/null
log "push triggered in background"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
POST_COMMIT_HOOK="$REPO_ROOT/.github/hooks/post-commit"
if [ -x "$POST_COMMIT_HOOK" ]; then
  "$POST_COMMIT_HOOK" </dev/null >/dev/null 2>&1 || log "post-commit uploader failed"
else
  log "post-commit uploader not installed"
fi

exit 0
