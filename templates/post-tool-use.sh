#!/bin/bash
# Gitprint — PostToolUse Hook (Claude Code)
# Fires after every tool call. Tracks transcript path + checkpoint only.
# The actual note write + ingest happens in post-commit.sh on the new HEAD.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint] $*" >&2; }

INPUT=$(cat)

# Fast filter: only act on file-modifying tools
TOOL=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).tool_name||''); } catch { console.log(''); }
  });
")
case "$TOOL" in
  Edit|Write|MultiEdit|str_replace|str_replace_editor|create|file_write|edit) ;;
  *) exit 0 ;;
esac

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

echo "$INPUT" | GIT_DIR="$GIT_DIR" node -e '
(async () => {
  const fs = require("fs");
  let stdin = "";
  for await (const c of process.stdin) stdin += c;
  let payload;
  try { payload = JSON.parse(stdin); } catch { process.exit(0); }

  const transcriptPath = payload.transcript_path;
  const sessionId = payload.session_id || "unknown";
  if (!transcriptPath) process.exit(0);

  const gitDir = process.env.GIT_DIR;
  const activeFile = require("path").join(gitDir, "gitprint-active.json");

  // Write active marker — post-commit.sh uses this to find the transcript
  fs.writeFileSync(activeFile, JSON.stringify({
    transcript_path: transcriptPath,
    session_id: sessionId,
    updated: new Date().toISOString(),
  }));
})().catch(e => process.stderr.write(`[gitprint] post-tool-use error: ${e.message}\n`));
'

exit 0
unknown";
  if (!transcriptPath || !fs.existsSync(transcriptPath)) process.exit(0);

  // ─── Read checkpoint ───
  let lastLine = 0;
  try {
    const cp = JSON.parse(fs.readFileSync(process.env.CHECKPOINT_FILE, "utf8"));
    if (cp.transcript_path === transcriptPath) lastLine = cp.last_line || 0;
  } catch {}

  // ─── Parse transcript delta ───
  const allLines = fs.readFileSync(transcriptPath, "utf8").split("\n").filter(Boolean);
  const deltaLines = allLines.slice(lastLine);
  if (deltaLines.length === 0) process.exit(0);

  let inputTokens = 0, outputTokens = 0, cacheCreation = 0, cacheRead = 0, turns = 0, apiCalls = 0;
  const models = {};
  const fileLineStats = {};

  const countLines = (s) => !s ? 0 : String(s).split("\n").length;

  let repoRoot = process.cwd();
  try { repoRoot = execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim(); } catch {}

  const trackFile = (fp, added, removed) => {
    if (!fp) return;
    fp = fp.replace(/^\.\//, "");
    if (fp.startsWith("/")) {
      if (fp.startsWith(repoRoot + "/")) fp = fp.slice(repoRoot.length + 1);
      else return;
    } else {
      const abs = path.resolve(process.cwd(), fp);
      if (abs.startsWith(repoRoot + "/")) fp = abs.slice(repoRoot.length + 1);
    }
    if (fp.includes(".ai-stats") || fp.includes("node_modules")) return;
    if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
    fileLineStats[fp].added += added;
    fileLineStats[fp].removed += removed;
  };

  for (const line of deltaLines) {
    try {
      const entry = JSON.parse(line);
      if (entry.isSidechain || entry.isApiErrorMessage) continue;
      if (entry.type === "human") turns++;

      if (entry.type === "assistant" && entry.message?.usage) {
        const u = entry.message.usage;
        const inp = u.input_tokens || 0;
        const out = u.output_tokens || 0;
        const cc = u.cache_creation_input_tokens || 0;
        const cr = u.cache_read_input_tokens || 0;
        inputTokens += inp; outputTokens += out;
        cacheCreation += cc; cacheRead += cr;
        apiCalls++;
        const model = entry.model || entry.message?.model || "unknown";
        if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
        models[model].input_tokens += inp + cc + cr;
        models[model].output_tokens += out;
        models[model].api_calls++;
      }

      if (entry.type === "assistant" && entry.message?.content) {
        for (const block of entry.message.content) {
          if (block.type !== "tool_use") continue;
          const name = block.name || "";
          const input = block.input || {};
          if (/^(Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            const oldStr = input.old_str || input.old_string || input.oldStr || "";
            const newStr = input.new_str || input.new_string || input.newStr || input.replacement || "";
            trackFile(fp, countLines(newStr), countLines(oldStr));
          }
          if (/^MultiEdit$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            for (const e of (input.edits || [])) {
              trackFile(fp, countLines(e.new_str || e.new_string || ""), countLines(e.old_str || e.old_string || ""));
            }
          }
          if (/^(Write|Create|file_write|create_file|write)$/i.test(name)) {
            const fp = input.file_path || input.path || input.filePath;
            trackFile(fp, countLines(input.content || input.file_text || ""), 0);
          }
        }
      }
    } catch {}
  }

  // ─── Cost ───
  const pricing = {
    opus:   { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
    sonnet: { input: 3,  output: 15, cache_read: 0.30, cache_creation: 3.75 },
    haiku:  { input: 1,  output: 5,  cache_read: 0.10, cache_creation: 1.25 },
  };
  const matchPricing = (m) => {
    const ml = (m || "").toLowerCase();
    if (ml.includes("opus")) return pricing.opus;
    if (ml.includes("sonnet")) return pricing.sonnet;
    if (ml.includes("haiku")) return pricing.haiku;
    return pricing.sonnet;
  };
  let estimatedCost = 0;
  for (const [m, info] of Object.entries(models)) {
    const p = matchPricing(m);
    estimatedCost += (info.input_tokens / 1e6) * p.input;
    estimatedCost += (info.output_tokens / 1e6) * p.output;
  }
  const dom = Object.keys(models).sort((a, b) =>
    (models[b].input_tokens + models[b].output_tokens) - (models[a].input_tokens + models[a].output_tokens))[0] || "";
  const dp = matchPricing(dom);
  estimatedCost += (cacheCreation / 1e6) * dp.cache_creation;
  estimatedCost += (cacheRead / 1e6) * dp.cache_read;

  const aiFiles = Object.entries(fileLineStats).map(([file, s]) => ({
    file, ai_lines_added: s.added, ai_lines_removed: s.removed
  }));

  // Skip writing if delta yielded nothing useful
  const hasContent = aiFiles.length > 0 || (inputTokens + outputTokens + cacheCreation + cacheRead) > 0;
  if (!hasContent) {
    fs.writeFileSync(process.env.CHECKPOINT_FILE,
      JSON.stringify({ transcript_path: transcriptPath, last_line: allLines.length }));
    process.exit(0);
  }

  // ─── Merge with existing note ───
  let data;
  try { data = JSON.parse(process.env.EXISTING_NOTE || "{}"); } catch { data = {}; }
  if (!data.sessions) data.sessions = [];
  if (!data.ai_files) data.ai_files = [];

  const fileMap = {};
  for (const f of data.ai_files) {
    fileMap[f.file] = { ai_lines_added: f.ai_lines_added || 0, ai_lines_removed: f.ai_lines_removed || 0 };
  }
  for (const f of aiFiles) {
    if (!fileMap[f.file]) fileMap[f.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
    fileMap[f.file].ai_lines_added += f.ai_lines_added;
    fileMap[f.file].ai_lines_removed += f.ai_lines_removed;
  }
  data.ai_files = Object.entries(fileMap).map(([file, s]) => ({ file, ...s }));

  const newSession = {
    session_id: sessionId,
    tool: "claude-code",
    timestamp: new Date().toISOString(),
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_creation_tokens: cacheCreation,
    cache_read_tokens: cacheRead,
    estimated_cost: Math.round(estimatedCost * 10000) / 10000,
    turns, api_calls: apiCalls, models,
  };
  const ex = data.sessions.find(s => s.session_id === sessionId);
  if (!ex) {
    data.sessions.push(newSession);
  } else {
    ex.input_tokens = (ex.input_tokens || 0) + inputTokens;
    ex.output_tokens = (ex.output_tokens || 0) + outputTokens;
    ex.cache_creation_tokens = (ex.cache_creation_tokens || 0) + cacheCreation;
    ex.cache_read_tokens = (ex.cache_read_tokens || 0) + cacheRead;
    ex.estimated_cost = (ex.estimated_cost || 0) + newSession.estimated_cost;
    ex.turns = (ex.turns || 0) + turns;
    ex.api_calls = (ex.api_calls || 0) + apiCalls;
    ex.timestamp = newSession.timestamp;
    ex.models = ex.models || {};
    for (const [m, info] of Object.entries(models)) {
      if (!ex.models[m]) ex.models[m] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
      ex.models[m].input_tokens += info.input_tokens;
      ex.models[m].output_tokens += info.output_tokens;
      ex.models[m].api_calls += info.api_calls;
    }
  }

  // ─── Write note + checkpoint + active marker ───
  try {
    execSync(`git notes --ref=gitprint add -f --file=- ${process.env.HEAD_SHA}`,
      { input: JSON.stringify(data), stdio: ["pipe", "ignore", "pipe"] });
  } catch (e) { process.stderr.write(`[gitprint] note write failed: ${e.message}\n`); }

  fs.writeFileSync(process.env.CHECKPOINT_FILE,
    JSON.stringify({ transcript_path: transcriptPath, last_line: allLines.length }));
  fs.writeFileSync(process.env.ACTIVE_FILE,
    JSON.stringify({ transcript_path: transcriptPath, session_id: sessionId, updated: new Date().toISOString() }));
})().catch(e => process.stderr.write(`[gitprint] post-tool-use error: ${e.message}\n`));
'

exit 0
