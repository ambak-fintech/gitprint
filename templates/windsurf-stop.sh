#!/bin/bash
# Gitprint — Windsurf Stop Hook
# Fires via post_cascade_response_with_transcript hook
# Parses transcript for per-file AI line counts
# NOTE: Windsurf transcripts do NOT contain token usage data
# Stores data as a Git Note on HEAD (no files to commit/cleanup)

# ─── Logging ───
log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:windsurf] $*" >&2; }
log_err() { echo "[gitprint:windsurf] ERROR: $*" >&2; }

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
      console.log(j.trajectory_id || j.execution_id || j.session_id || 'unknown');
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

  // Windsurf does NOT provide token data — set to 0
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
  lines.forEach((line, idx) => {
    try {
      const e = JSON.parse(line);
      if ((e.type === 'assistant' || e.role === 'assistant') && e.message?.id) lastIndexById[e.message.id] = idx;
    } catch {}
  });

  lines.forEach((line, idx) => {
    try {
      const entry = JSON.parse(line);

      // Count user messages as turns
      if (entry.type === 'human' || entry.role === 'user') turns++;

      if ((entry.type === 'assistant' || entry.role === 'assistant') && entry.message?.id) {
        if (idx !== lastIndexById[entry.message.id]) return; // skip partial streaming chunk
      }

      // Count API calls from assistant responses (best effort)
      if (entry.type === 'assistant' || entry.role === 'assistant') {
        apiCalls++;
        const model = entry.model || entry.message?.model || '';
        if (model) {
          if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
          models[model].api_calls++;
        }
      }

      // Token tracking — grab if available (may exist in future versions)
      if (entry.message?.usage || entry.usage) {
        const u = entry.message?.usage || entry.usage;
        const inp = u.input_tokens || u.prompt_tokens || 0;
        const out = u.output_tokens || u.completion_tokens || 0;
        inputTokens += inp;
        outputTokens += out;

        const model = entry.model || entry.message?.model || 'unknown';
        if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
        models[model].input_tokens += inp;
        models[model].output_tokens += out;
      }

      // File + line tracking from tool_use blocks (content array)
      if (entry.message?.content || entry.content) {
        const content = entry.message?.content || entry.content;
        if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type !== 'tool_use') continue;
            const name = block.name || '';
            const input = block.input || {};

            // Edit / str_replace / replace
            if (/^(Edit|str_replace|str_replace_editor|edit|replace)$/i.test(name)) {
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
            if (/^(Write|Create|file_write|create_file|write|write_file)$/i.test(name)) {
              const fp = input.file_path || input.path || input.filePath;
              trackFile(fp, countLines(input.content || input.file_text || ''), 0);
            }
          }
        }
      }

      // Tool use at entry level
      if (entry.type === 'tool_use' || entry.type === 'tool_call') {
        const name = entry.name || entry.tool_name || '';
        const input = entry.input || entry.args || {};

        if (/^(Edit|str_replace|str_replace_editor|edit|replace)$/i.test(name)) {
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

        if (/^(Write|Create|file_write|create_file|write|write_file)$/i.test(name)) {
          const fp = input.file_path || input.path || input.filePath;
          trackFile(fp, countLines(input.content || input.file_text || ''), 0);
        }
      }
    } catch (e) {}
  });

  const aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
    file, ai_lines_added: s.added, ai_lines_removed: s.removed
  }));

  console.log(JSON.stringify({
    session_id: '$SESSION_ID',
    tool: 'windsurf',
    timestamp: new Date().toISOString(),
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_creation_tokens: cacheCreation,
    cache_read_tokens: cacheRead,
    estimated_cost: 0,
    turns,
    api_calls: apiCalls,
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
