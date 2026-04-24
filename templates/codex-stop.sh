#!/bin/bash
# Gitprint — OpenAI Codex Stop Hook
# Fires when a Codex conversation turn ends.
# Parses transcript for token usage and apply_patch file edits.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:codex] $*" >&2; }
log_err() { echo "[gitprint:codex] ERROR: $*" >&2; }

# ─── Read stdin ───
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).session_id||''); } catch { console.log(''); } });
")
TRANSCRIPT_PATH=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).transcript_path||''); } catch { console.log(''); } });
")
MODEL=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).model||''); } catch { console.log(''); } });
")

[ -n "$SESSION_ID" ] || { log "no session_id — skipping"; exit 0; }
[ -f "$TRANSCRIPT_PATH" ] || { log "transcript not found: $TRANSCRIPT_PATH"; exit 0; }

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || { log "not a git repo"; exit 0; }
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null) || { log "no HEAD commit"; exit 0; }
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

log "session=$SESSION_ID model=$MODEL transcript=$TRANSCRIPT_PATH"

# ─── Parse transcript ───
STATS=$(node -e "
  const fs = require('fs');
  const path = require('path');

  const lines = fs.readFileSync('$TRANSCRIPT_PATH', 'utf8').split('\n').filter(Boolean);
  const repoRoot = '$REPO_ROOT';

  let inputTokens = 0, outputTokens = 0, cacheCreation = 0, cacheRead = 0, reasoningTokens = 0;
  let turns = 0, apiCalls = 0;
  const models = {};
  const fileLineStats = {};

  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\\.\//, '').replace(/^a\/|^b\//, '');
    if (fp.startsWith('/')) {
      if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1);
      else return;
    }
    if (fp.includes('node_modules') || fp.includes('.git/')) return;
    if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
    fileLineStats[fp].added += added;
    fileLineStats[fp].removed += removed;
  };

  // Parse unified diff (apply_patch format)
  const parsePatch = (patchText) => {
    if (!patchText) return;
    const lines = patchText.split('\n');
    let currentFile = null;
    let added = 0, removed = 0;

    for (const line of lines) {
      // New file: '*** Update File: path' or '--- a/path' or '+++ b/path'
      const updateMatch = line.match(/^\*\*\* (?:Update File|Add File|Create File):\s*(.+)/);
      if (updateMatch) {
        if (currentFile) trackFile(currentFile, added, removed);
        currentFile = updateMatch[1].trim();
        added = 0; removed = 0;
        continue;
      }
      const diffAMatch = line.match(/^--- a\/(.+)/);
      if (diffAMatch && !line.startsWith('--- a/dev/null')) {
        if (currentFile) trackFile(currentFile, added, removed);
        currentFile = diffAMatch[1].trim();
        added = 0; removed = 0;
        continue;
      }
      // Count +/- lines (skip @@ and file headers)
      if (line.startsWith('+') && !line.startsWith('+++')) { added++; }
      if (line.startsWith('-') && !line.startsWith('---')) { removed++; }
    }
    if (currentFile) trackFile(currentFile, added, removed);
  };

  // Track previous token_count for delta calc (token_count events are cumulative)
  let prevTokens = { input: 0, output: 0, cacheCreate: 0, cacheRead: 0, reasoning: 0 };

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      const type = entry.type || '';
      const payload = entry.payload || entry;

      // Token count events (cumulative — calc delta)
      if (type === 'token_count' || payload.input_tokens != null) {
        const p = payload;
        const inp = (p.input_tokens || 0) - prevTokens.input;
        const out = (p.output_tokens || 0) - prevTokens.output;
        const cc  = (p.cache_creation_tokens || 0) - prevTokens.cacheCreate;
        const cr  = (p.cache_read_tokens || 0) - prevTokens.cacheRead;
        const rs  = (p.reasoning_tokens || 0) - prevTokens.reasoning;

        if (inp > 0 || out > 0) {
          inputTokens += Math.max(0, inp);
          outputTokens += Math.max(0, out);
          cacheCreation += Math.max(0, cc);
          cacheRead += Math.max(0, cr);
          reasoningTokens += Math.max(0, rs);
          apiCalls++;

          const model = entry.model || '$MODEL' || 'unknown';
          if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
          models[model].input_tokens += Math.max(0, inp) + Math.max(0, cc) + Math.max(0, cr);
          models[model].output_tokens += Math.max(0, out);
          models[model].api_calls++;

          prevTokens = {
            input: p.input_tokens || 0,
            output: p.output_tokens || 0,
            cacheCreate: p.cache_creation_tokens || 0,
            cacheRead: p.cache_read_tokens || 0,
            reasoning: p.reasoning_tokens || 0,
          };
        }
      }

      // Human turns
      if (type === 'human' || type === 'user_message' || payload.role === 'user') turns++;

      // apply_patch tool use — parse the patch for file attribution
      const toolName = payload.tool || payload.tool_name || payload.name || '';
      const toolInput = payload.input || payload.tool_input || payload.arguments || {};

      if (/apply_patch/i.test(toolName)) {
        const patch = toolInput.patch || toolInput.input || toolInput.content || '';
        if (patch) parsePatch(patch);
      }

      // Also check nested tool_use blocks (assistant message format)
      const content = payload.content || (entry.message && entry.message.content) || [];
      if (Array.isArray(content)) {
        for (const block of content) {
          if ((block.type === 'tool_use' || block.name) && /apply_patch/i.test(block.name || '')) {
            const patch = (block.input || {}).patch || (block.input || {}).input || '';
            if (patch) parsePatch(patch);
          }
        }
      }
    } catch (e) {}
  }

  // ─── Cost estimation ───
  const pricing = {
    'gpt-4': { input: 10, output: 30, cache_read: 1.0, cache_creation: 0 },
    'gpt-4o': { input: 2.5, output: 10, cache_read: 1.25, cache_creation: 0 },
    'gpt-4.1': { input: 2, output: 8, cache_read: 0.5, cache_creation: 0 },
    'o1': { input: 15, output: 60, cache_read: 7.5, cache_creation: 0 },
    'o3': { input: 10, output: 40, cache_read: 2.5, cache_creation: 0 },
    'codex': { input: 2, output: 8, cache_read: 0.5, cache_creation: 0 },
  };
  const matchPricing = (m) => {
    const ml = (m || '').toLowerCase();
    if (ml.includes('o3')) return pricing.o3;
    if (ml.includes('o1')) return pricing.o1;
    if (ml.includes('gpt-4.1') || ml.includes('gpt4.1')) return pricing['gpt-4.1'];
    if (ml.includes('gpt-4o') || ml.includes('gpt4o')) return pricing['gpt-4o'];
    if (ml.includes('gpt-4') || ml.includes('gpt4')) return pricing['gpt-4'];
    return pricing.codex;
  };

  let estimatedCost = 0;
  for (const [model, info] of Object.entries(models)) {
    const p = matchPricing(model);
    estimatedCost += (info.input_tokens / 1e6) * p.input;
    estimatedCost += (info.output_tokens / 1e6) * p.output;
  }
  const dominantModel = Object.keys(models).sort((a, b) =>
    (models[b].input_tokens + models[b].output_tokens) - (models[a].input_tokens + models[a].output_tokens)
  )[0] || '$MODEL' || '';
  const dp = matchPricing(dominantModel);
  estimatedCost += (cacheRead / 1e6) * dp.cache_read;

  const aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
    file, ai_lines_added: s.added, ai_lines_removed: s.removed
  }));

  console.log(JSON.stringify({
    session_id: '$SESSION_ID',
    tool: 'codex',
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
  }));
")

[ -z "$STATS" ] || [ "$STATS" = "null" ] && { log "empty stats"; exit 0; }

# ─── Prefer pending file for ai_files (written by post-tool hook) ───
PENDING_FILE="$GIT_DIR/gitprint-codex-pending.json"
if [ -f "$PENDING_FILE" ]; then
  STATS=$(node -e "
    const fs = require('fs');
    const stats = JSON.parse(process.argv[1]);
    const pending = JSON.parse(fs.readFileSync('$PENDING_FILE', 'utf8'));
    stats.ai_files = Object.entries(pending).map(([file, s]) => ({
      file, ai_lines_added: s.added || 0, ai_lines_removed: s.removed || 0
    }));
    console.log(JSON.stringify(stats));
  " "$STATS")
  rm -f "$PENDING_FILE"
  log "merged pending file into stats"
fi

AI_FILES_COUNT=$(echo "$STATS" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log((JSON.parse(d).ai_files||[]).length); } catch { console.log(0); } });
")
TOKENS=$(echo "$STATS" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { const s=JSON.parse(d); console.log((s.input_tokens||0)+(s.output_tokens||0)); } catch { console.log(0); }
  });
")

[ "$AI_FILES_COUNT" = "0" ] && [ "$TOKENS" = "0" ] && { log "no data to record"; exit 0; }

# ─── Merge with existing note ───
MERGED=$(node -e "
  const existing = process.argv[1] || '{}';
  const newStats = JSON.parse(process.argv[2]);

  let data;
  try { data = JSON.parse(existing); } catch { data = {}; }
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
  const exists = data.sessions.find(s => s.session_id === session.session_id);
  if (!exists) data.sessions.push(session);
  else Object.assign(exists, session);

  console.log(JSON.stringify(data));
" "$(git notes --ref=gitprint show "$HEAD_SHA" 2>/dev/null || echo '{}')" "$STATS")

# ─── Write git note ───
NOTE_ERR=$(echo "$MERGED" | git notes --ref=gitprint add -f --file=- "$HEAD_SHA" 2>&1) || log_err "git notes write failed: $NOTE_ERR"
log "note written to $HEAD_SHA (files=$AI_FILES_COUNT tokens=$TOKENS)"

# ─── Push notes ───
git push origin refs/notes/gitprint </dev/null 2>/dev/null &
disown 2>/dev/null
log "push triggered in background"

exit 0
