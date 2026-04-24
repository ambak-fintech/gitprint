// Gitprint — OpenCode Plugin
// Auto-loaded from .opencode/plugins/gitprint.js
// Tracks OpenCode file edits and token usage, attaches file deltas via
// post-commit, and writes any leftover session data on session idle.

const fs = require('fs');
const path = require('path');
const { execSync, spawn } = require('child_process');

const DEBUG = process.env.GITPRINT_DEBUG === '1';
const log = (...args) => { if (DEBUG) console.error('[gitprint:opencode]', ...args); };
const logErr = (...args) => { console.error('[gitprint:opencode] ERROR:', ...args); };

const countLines = (str) => {
  if (!str) return 0;
  const s = String(str);
  return s.length === 0 ? 0 : s.split('\n').length;
};

const readJson = (filePath, fallback) => {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
};

const writeJson = (filePath, data) => {
  fs.writeFileSync(filePath, JSON.stringify(data));
};

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

const mergeNote = (existingRaw, newStats) => {
  let data;
  try {
    data = JSON.parse(existingRaw || '{}');
  } catch {
    data = {};
  }

  if (!data.sessions) data.sessions = [];
  if (!data.ai_files) data.ai_files = [];

  const fileMap = {};
  for (const file of data.ai_files) {
    fileMap[file.file] = {
      ai_lines_added: file.ai_lines_added || 0,
      ai_lines_removed: file.ai_lines_removed || 0,
    };
  }
  for (const file of (newStats.ai_files || [])) {
    if (!fileMap[file.file]) fileMap[file.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
    fileMap[file.file].ai_lines_added += file.ai_lines_added || 0;
    fileMap[file.file].ai_lines_removed += file.ai_lines_removed || 0;
  }
  data.ai_files = Object.entries(fileMap).map(([file, stats]) => ({
    file,
    ai_lines_added: stats.ai_lines_added,
    ai_lines_removed: stats.ai_lines_removed,
  }));

  if (newStats.session_id) {
    const session = { ...newStats };
    delete session.ai_files;
    const existingSession = data.sessions.find((entry) => entry.session_id === session.session_id);
    if (!existingSession) data.sessions.push(session);
    else mergeSession(existingSession, session);
  }

  return JSON.stringify(data);
};

async function GitprintPlugin(ctx = {}) {
  const executionCwd = ctx.directory || ctx.worktree || process.cwd();
  const repoRoot = (() => {
    try {
      return execSync('git rev-parse --show-toplevel', { encoding: 'utf8', cwd: executionCwd }).trim();
    } catch {
      return executionCwd;
    }
  })();

  let gitDir;
  try {
    gitDir = execSync('git rev-parse --git-dir', { encoding: 'utf8', cwd: executionCwd }).trim();
  } catch {
    gitDir = null;
  }

  const pendingFile = gitDir ? path.join(gitDir, 'gitprint-opencode-pending.json') : null;
  const activeFile = gitDir ? path.join(gitDir, 'gitprint-opencode-active.json') : null;
  const checkpointFile = gitDir ? path.join(gitDir, 'gitprint-opencode-checkpoint.json') : null;

  let sessionId = 'unknown';
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheCreation = 0;
  let cacheRead = 0;
  let turns = 0;
  let apiCalls = 0;
  const models = {};

  const normalizeFile = (filePath) => {
    if (!filePath) return null;
    let fp = String(filePath).replace(/^\.\//, '');
    if (fp.startsWith('/')) {
      if (!fp.startsWith(repoRoot + '/')) return null;
      fp = fp.slice(repoRoot.length + 1);
    } else {
      const abs = path.resolve(executionCwd, fp);
      if (abs.startsWith(repoRoot + '/')) fp = abs.slice(repoRoot.length + 1);
    }
    if (fp.includes('node_modules')) return null;
    return fp;
  };

  const updatePendingFile = (updates) => {
    if (!pendingFile || !activeFile) return;
    const pending = readJson(pendingFile, {});
    for (const { file, added, removed } of updates) {
      if (!file) continue;
      if (!pending[file]) pending[file] = { added: 0, removed: 0 };
      pending[file].added += added;
      pending[file].removed += removed;
    }
    writeJson(pendingFile, pending);
    writeJson(activeFile, {
      cwd: executionCwd,
      session_id: sessionId,
      updated: new Date().toISOString(),
    });
  };

  const captureUsage = (event) => {
    const usage = event.usage || event.message?.usage || event.data?.usage || null;
    if (!usage) return;

    const inp = usage.input_tokens || usage.prompt_tokens || 0;
    const out = usage.output_tokens || usage.completion_tokens || 0;
    const cc = usage.cache_creation_input_tokens || usage.cache_creation_tokens || 0;
    const cr = usage.cache_read_input_tokens || usage.cache_read_tokens || 0;

    inputTokens += inp;
    outputTokens += out;
    cacheCreation += cc;
    cacheRead += cr;
    turns++;
    apiCalls++;

    const model = event.model || event.message?.model || event.data?.model || 'unknown';
    if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
    models[model].input_tokens += inp + cc + cr;
    models[model].output_tokens += out;
    models[model].api_calls++;
  };

  const pricing = {
    opus: { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
    sonnet: { input: 3, output: 15, cache_read: 0.30, cache_creation: 3.75 },
    haiku: { input: 1, output: 5, cache_read: 0.10, cache_creation: 1.25 },
    'gpt-4o': { input: 2.50, output: 10, cache_read: 1.25, cache_creation: 2.50 },
    'gpt-4o-mini': { input: 0.15, output: 0.60, cache_read: 0.075, cache_creation: 0.15 },
    o1: { input: 15, output: 60, cache_read: 7.50, cache_creation: 15 },
    o3: { input: 10, output: 40, cache_read: 5, cache_creation: 10 },
    'o3-mini': { input: 1.10, output: 4.40, cache_read: 0.55, cache_creation: 1.10 },
    'gemini-2.5-pro': { input: 1.25, output: 10, cache_read: 0.315, cache_creation: 1.25 },
    'gemini-2.5-flash': { input: 0.15, output: 0.60, cache_read: 0.0375, cache_creation: 0.15 },
  };

  const matchPricing = (modelName) => {
    const lower = (modelName || '').toLowerCase();
    for (const [key, rates] of Object.entries(pricing)) {
      if (lower.includes(key)) return rates;
    }
    if (lower.includes('opus')) return pricing.opus;
    if (lower.includes('sonnet')) return pricing.sonnet;
    if (lower.includes('haiku')) return pricing.haiku;
    return pricing.sonnet;
  };

  const flushSession = async () => {
    try {
      if (!gitDir || !pendingFile) return;

      const pending = readJson(pendingFile, {});
      const checkpoint = readJson(checkpointFile, { files: {} });
      const leftoverFiles = deltaFromCheckpoint(pending, checkpoint.files || {});
      const aiFiles = Object.entries(leftoverFiles).map(([file, stats]) => ({
        file,
        ai_lines_added: stats.added || 0,
        ai_lines_removed: stats.removed || 0,
      }));

      const hasFiles = aiFiles.length > 0;
      const hasTokens = inputTokens > 0 || outputTokens > 0 || cacheCreation > 0 || cacheRead > 0;
      if (!hasFiles && !hasTokens) {
        log('no OpenCode data to write');
        try { fs.rmSync(pendingFile, { force: true }); } catch {}
        try { fs.rmSync(activeFile, { force: true }); } catch {}
        try { fs.rmSync(checkpointFile, { force: true }); } catch {}
        return;
      }

      let estimatedCost = 0;
      for (const [model, info] of Object.entries(models)) {
        const rates = matchPricing(model);
        estimatedCost += (info.input_tokens / 1e6) * rates.input;
        estimatedCost += (info.output_tokens / 1e6) * rates.output;
      }
      const dominantModel = Object.keys(models).sort((a, b) =>
        (models[b].input_tokens + models[b].output_tokens) - (models[a].input_tokens + models[a].output_tokens),
      )[0] || '';
      const dominantRates = matchPricing(dominantModel);
      estimatedCost += (cacheCreation / 1e6) * dominantRates.cache_creation;
      estimatedCost += (cacheRead / 1e6) * dominantRates.cache_read;

      const sessionData = {
        session_id: sessionId,
        tool: 'opencode',
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
      };

      let headSha;
      try {
        headSha = execSync('git rev-parse HEAD', { encoding: 'utf8', cwd: executionCwd }).trim();
      } catch {
        logErr('not in a git repo or no commits');
        return;
      }

      const merged = mergeNote((() => {
        try {
          return execSync(`git notes --ref=gitprint show ${headSha}`, { encoding: 'utf8', cwd: executionCwd }).trim();
        } catch {
          return '{}';
        }
      })(), sessionData);

      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        cwd: executionCwd,
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      log('note written to', headSha);

      try {
        const pushProc = spawn('git', ['push', 'origin', 'refs/notes/gitprint'], {
          cwd: executionCwd,
          stdio: 'ignore',
          detached: true,
        });
        pushProc.unref();
      } catch {}

      try {
        const postCommitHook = path.join(repoRoot, '.github', 'hooks', 'post-commit');
        if (fs.existsSync(postCommitHook)) {
          execSync(`"${postCommitHook}"`, { stdio: 'ignore' });
        }
      } catch {
        log('post-commit uploader failed');
      }
    } catch (error) {
      logErr('session.idle handler failed:', error.message);
    } finally {
      try { fs.rmSync(pendingFile, { force: true }); } catch {}
      try { fs.rmSync(activeFile, { force: true }); } catch {}
      try { fs.rmSync(checkpointFile, { force: true }); } catch {}

      inputTokens = 0;
      outputTokens = 0;
      cacheCreation = 0;
      cacheRead = 0;
      turns = 0;
      apiCalls = 0;
      sessionId = 'unknown';
      for (const key of Object.keys(models)) delete models[key];
    }
  };

  return {
    'tool.execute.after': async (input = {}, output = {}) => {
      try {
        const name = String(input.tool || input.name || input.toolName || output.tool || output.name || '').toLowerCase();
        const args = output.args || input.args || input.input || input.tool_input || {};
        const updates = [];

        if (/^(edit|str_replace|str_replace_editor|replace)$/.test(name)) {
          const file = normalizeFile(args.file_path || args.path || args.filePath);
          updates.push({
            file,
            added: countLines(args.new_str || args.new_string || args.newStr || args.replacement || ''),
            removed: countLines(args.old_str || args.old_string || args.oldStr || ''),
          });
        }

        if (/^(write|create|file_write|create_file|write_file)$/.test(name)) {
          const file = normalizeFile(args.file_path || args.path || args.filePath);
          updates.push({
            file,
            added: countLines(args.content || args.file_text || ''),
            removed: 0,
          });
        }

        if (/^(multi_edit|multiedit)$/.test(name)) {
          const file = normalizeFile(args.file_path || args.path || args.filePath);
          for (const edit of (args.edits || [])) {
            updates.push({
              file,
              added: countLines(edit.new_str || edit.new_string || ''),
              removed: countLines(edit.old_str || edit.old_string || ''),
            });
          }
        }

        if (updates.length > 0) updatePendingFile(updates);
      } catch (error) {
        logErr('tool.execute.after handler failed:', error.message);
      }
    },
    event: async ({ event } = {}) => {
      try {
        if (!event) return;

        if (event.session_id || event.sessionID || event.session?.id) {
          sessionId = event.session_id || event.sessionID || event.session?.id || sessionId;
        }

        if (event.type === 'message.updated' || event.type === 'session.updated') {
          captureUsage(event);
        }

        if (event.type === 'session.idle') {
          await flushSession();
        }
      } catch (error) {
        logErr('event handler failed:', error.message);
      }
    },
  };
}

module.exports = { GitprintPlugin };
