#!/bin/bash
# Gitprint — Post-Commit Hook
# Fires after every git commit. Attaches any active Claude delta to the new
# commit as a git note, then POSTs local note data to the platform.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint] $*" >&2; }
log_err() { echo "[gitprint] ERROR: $*" >&2; }

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
CONFIG_FILE="$GIT_DIR/gitprint-config"

PLATFORM_URL="${AI_PLATFORM_URL:-$(git config --global gitprint.platformUrl 2>/dev/null || true)}"
PLATFORM_TOKEN="${AI_PLATFORM_TOKEN:-${AI_PLATFORM_KEY:-$(git config --global gitprint.platformToken 2>/dev/null || true)}}"

if [ -z "$PLATFORM_URL" ] || [ -z "$PLATFORM_TOKEN" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    [ -n "$PLATFORM_URL" ] || PLATFORM_URL=$(grep '^AI_PLATFORM_URL=' "$CONFIG_FILE" | cut -d= -f2-)
    [ -n "$PLATFORM_TOKEN" ] || PLATFORM_TOKEN=$(grep '^AI_PLATFORM_TOKEN=' "$CONFIG_FILE" | cut -d= -f2-)
  else
    log "no gitprint-config — platform ingest disabled"
  fi
fi

BASE_BRANCH=$(git config gitprint.baseBranch 2>/dev/null || echo 'main')
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo '')
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo '')
REPO=$(echo "$REMOTE_URL" | sed 's|.*github\.com[:/]||' | sed 's|\.git$||')
SENDER=$(git config user.email 2>/dev/null || git config user.name 2>/dev/null || echo 'unknown')

log "post-commit: branch=${CURRENT_BRANCH:-detached} base=$BASE_BRANCH repo=$REPO sender=$SENDER"

node - "$PLATFORM_URL" "$PLATFORM_TOKEN" "$BASE_BRANCH" "$CURRENT_BRANCH" "$REPO" "$SENDER" "$GIT_DIR" << 'NODEEOF'
(async () => {
  const { execSync, spawn } = require('child_process');
  const fs = require('fs');
  const path = require('path');
  const https = require('https');
  const http = require('http');

  const [platformUrl, platformToken, base, branch, repo, sender, gitDir] = process.argv.slice(2);
  const activeFile = path.join(gitDir, 'gitprint-active.json');
  const checkpointFile = path.join(gitDir, 'gitprint-checkpoint.json');
  const copilotActiveFile = path.join(gitDir, 'gitprint-copilot-active.json');
  const copilotPendingFile = path.join(gitDir, 'gitprint-copilot-pending.json');
  const copilotCheckpointFile = path.join(gitDir, 'gitprint-copilot-checkpoint.json');
  const geminiActiveFile = path.join(gitDir, 'gitprint-gemini-active.json');
  const geminiCheckpointFile = path.join(gitDir, 'gitprint-gemini-checkpoint.json');
  const codexActiveFile = path.join(gitDir, 'gitprint-codex-active.json');
  const codexCheckpointFile = path.join(gitDir, 'gitprint-codex-checkpoint.json');
  const windsurfActiveFile = path.join(gitDir, 'gitprint-windsurf-active.json');
  const windsurfCheckpointFile = path.join(gitDir, 'gitprint-windsurf-checkpoint.json');
  const augmentActiveFile = path.join(gitDir, 'gitprint-augment-active.json');
  const augmentPendingFile = path.join(gitDir, 'gitprint-augment-pending.json');
  const augmentCheckpointFile = path.join(gitDir, 'gitprint-augment-checkpoint.json');
  const opencodeActiveFile = path.join(gitDir, 'gitprint-opencode-active.json');
  const opencodePendingFile = path.join(gitDir, 'gitprint-opencode-pending.json');
  const opencodeCheckpointFile = path.join(gitDir, 'gitprint-opencode-checkpoint.json');
  const outboxFile = path.join(gitDir, 'gitprint-outbox.jsonl');

  function debug(message) {
    if (process.env.GITPRINT_DEBUG === '1') {
      process.stderr.write(`[gitprint] ${message}\n`);
    }
  }

  function readJson(filePath) {
    try {
      return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch {
      return null;
    }
  }

  function readGitNote(sha) {
    try {
      return execSync(`git notes --ref=gitprint show ${sha} 2>/dev/null`, { encoding: 'utf8' }).trim() || '{}';
    } catch {
      return '{}';
    }
  }

  function countLines(str) {
    if (!str) return 0;
    const s = String(str);
    return s.length === 0 ? 0 : s.split('\n').length;
  }

  function mergeSession(target, source) {
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
  }

  function mergeNote(existingRaw, newStats) {
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
      if (!fileMap[file.file]) {
        fileMap[file.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
      }
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
      delete session.transcript_line_count;

      const existingSession = data.sessions.find((entry) => entry.session_id === session.session_id);
      if (!existingSession) data.sessions.push(session);
      else mergeSession(existingSession, session);
    }

    return JSON.stringify(data);
  }

  function writeCheckpoint(transcriptPath, sessionId, lastLine) {
    try {
      fs.writeFileSync(checkpointFile, JSON.stringify({
        transcript_path: transcriptPath,
        session_id: sessionId || 'unknown',
        last_line: Number(lastLine || 0),
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function writeGeminiCheckpoint(transcriptPath, sessionId, lastLine) {
    try {
      fs.writeFileSync(geminiCheckpointFile, JSON.stringify({
        transcript_path: transcriptPath,
        session_id: sessionId || 'unknown',
        last_line: Number(lastLine || 0),
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function writeCodexCheckpoint(transcriptPath, sessionId, lastLine) {
    try {
      fs.writeFileSync(codexCheckpointFile, JSON.stringify({
        transcript_path: transcriptPath,
        session_id: sessionId || 'unknown',
        last_line: Number(lastLine || 0),
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function writeWindsurfCheckpoint(transcriptPath, sessionId, lastLine) {
    try {
      fs.writeFileSync(windsurfCheckpointFile, JSON.stringify({
        transcript_path: transcriptPath,
        session_id: sessionId || 'unknown',
        last_line: Number(lastLine || 0),
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function writeCopilotCheckpoint(cwd, files) {
    try {
      fs.writeFileSync(copilotCheckpointFile, JSON.stringify({
        cwd,
        files,
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function writeAugmentCheckpoint(cwd, files) {
    try {
      fs.writeFileSync(augmentCheckpointFile, JSON.stringify({
        cwd,
        files,
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function writeOpencodeCheckpoint(cwd, files) {
    try {
      fs.writeFileSync(opencodeCheckpointFile, JSON.stringify({
        cwd,
        files,
        updated: new Date().toISOString(),
      }));
    } catch {}
  }

  function fileDelta(currentFiles, previousFiles) {
    const delta = {};
    const allFiles = new Set([
      ...Object.keys(currentFiles || {}),
      ...Object.keys(previousFiles || {}),
    ]);

    for (const file of allFiles) {
      const current = currentFiles?.[file] || { added: 0, removed: 0 };
      const previous = previousFiles?.[file] || { added: 0, removed: 0 };
      const added = Math.max(0, (current.added || 0) - (previous.added || 0));
      const removed = Math.max(0, (current.removed || 0) - (previous.removed || 0));
      if (added > 0 || removed > 0) delta[file] = { added, removed };
    }

    return delta;
  }

  function pushNotesRef() {
    try {
      const child = spawn('git', ['push', 'origin', 'refs/notes/gitprint'], {
        stdio: 'ignore',
        detached: true,
      });
      child.unref();
    } catch {}
  }

  function parseClaudeDelta(transcriptPath, lastLine, sessionId) {
    const allLines = fs.readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);
    const deltaLines = allLines.slice(lastLine);

    if (deltaLines.length === 0) {
      return { empty: true, transcript_line_count: allLines.length };
    }

    let inputTokens = 0;
    let outputTokens = 0;
    let cacheCreation = 0;
    let cacheRead = 0;
    let turns = 0;
    let apiCalls = 0;
    const models = {};
    const fileLineStats = {};

    const repoRoot = (() => {
      try {
        return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
      } catch {
        return process.cwd();
      }
    })();

    const trackFile = (filePath, added, removed) => {
      if (!filePath) return;
      let relativePath = filePath.replace(/^\.\//, '');

      if (relativePath.startsWith('/')) {
        if (relativePath.startsWith(repoRoot + '/')) relativePath = relativePath.slice(repoRoot.length + 1);
        else return;
      } else {
        const absolutePath = path.resolve(process.cwd(), relativePath);
        if (absolutePath.startsWith(repoRoot + '/')) relativePath = absolutePath.slice(repoRoot.length + 1);
      }

      if (relativePath.includes('.ai-stats') || relativePath.includes('node_modules')) return;
      if (!fileLineStats[relativePath]) fileLineStats[relativePath] = { added: 0, removed: 0 };
      fileLineStats[relativePath].added += added;
      fileLineStats[relativePath].removed += removed;
    };

    for (const line of deltaLines) {
      try {
        const entry = JSON.parse(line);
        if (entry.isSidechain || entry.isApiErrorMessage) continue;

        if (entry.type === 'human') turns++;

        if (entry.type === 'assistant' && entry.message?.usage) {
          const usage = entry.message.usage;
          const inp = usage.input_tokens || 0;
          const out = usage.output_tokens || 0;
          const cc = usage.cache_creation_input_tokens || 0;
          const cr = usage.cache_read_input_tokens || 0;

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
              const filePath = input.file_path || input.path || input.filePath;
              const oldString = input.old_str || input.old_string || input.oldStr || '';
              const newString = input.new_str || input.new_string || input.newStr || input.replacement || '';
              trackFile(filePath, countLines(newString), countLines(oldString));
            }

            if (/^MultiEdit$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              for (const edit of (input.edits || [])) {
                trackFile(
                  filePath,
                  countLines(edit.new_str || edit.new_string || ''),
                  countLines(edit.old_str || edit.old_string || ''),
                );
              }
            }

            if (/^(Write|Create|file_write|create_file|write)$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              trackFile(filePath, countLines(input.content || input.file_text || ''), 0);
            }
          }
        }
      } catch {}
    }

    const aiFiles = Object.entries(fileLineStats).map(([file, stats]) => ({
      file,
      ai_lines_added: stats.added,
      ai_lines_removed: stats.removed,
    }));

    const pricing = {
      opus: { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
      sonnet: { input: 3, output: 15, cache_read: 0.30, cache_creation: 3.75 },
      haiku: { input: 1, output: 5, cache_read: 0.10, cache_creation: 1.25 },
    };
    const matchPricing = (modelName) => {
      const lower = modelName.toLowerCase();
      if (lower.includes('opus')) return pricing.opus;
      if (lower.includes('sonnet')) return pricing.sonnet;
      if (lower.includes('haiku')) return pricing.haiku;
      return pricing.sonnet;
    };

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

    return {
      session_id: sessionId,
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
      transcript_line_count: allLines.length,
    };
  }

  function parseGeminiDelta(transcriptPath, lastLine, sessionId, cwd) {
    const allLines = fs.readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);
    const deltaLines = allLines.slice(lastLine);

    if (deltaLines.length === 0) {
      return { empty: true, transcript_line_count: allLines.length };
    }

    let inputTokens = 0;
    let outputTokens = 0;
    let cacheCreation = 0;
    let cacheRead = 0;
    let turns = 0;
    let apiCalls = 0;
    const models = {};
    const fileLineStats = {};

    const repoRoot = (() => {
      try {
        return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
      } catch {
        return cwd || process.cwd();
      }
    })();

    const trackFile = (filePath, added, removed) => {
      if (!filePath) return;
      let relativePath = filePath.replace(/^\.\//, '');

      if (relativePath.startsWith('/')) {
        if (relativePath.startsWith(repoRoot + '/')) relativePath = relativePath.slice(repoRoot.length + 1);
        else return;
      } else {
        const absolutePath = path.resolve(cwd || process.cwd(), relativePath);
        if (absolutePath.startsWith(repoRoot + '/')) relativePath = absolutePath.slice(repoRoot.length + 1);
      }

      if (relativePath.includes('.ai-stats') || relativePath.includes('node_modules')) return;
      if (!fileLineStats[relativePath]) fileLineStats[relativePath] = { added: 0, removed: 0 };
      fileLineStats[relativePath].added += added;
      fileLineStats[relativePath].removed += removed;
    };

    for (const line of deltaLines) {
      try {
        const entry = JSON.parse(line);
        if (entry.isSidechain || entry.isApiErrorMessage) continue;

        if (entry.type === 'human' || entry.type === 'user') turns++;

        if (entry.type === 'assistant' && entry.message?.usage) {
          const usage = entry.message.usage;
          const inp = usage.input_tokens || 0;
          const out = usage.output_tokens || 0;
          const cc = usage.cache_creation_input_tokens || 0;
          const cr = usage.cache_read_input_tokens || 0;

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
          const usage = entry.usage;
          const inp = usage.input_tokens || usage.prompt_tokens || 0;
          const out = usage.output_tokens || usage.completion_tokens || 0;
          const cc = usage.cache_creation_input_tokens || 0;
          const cr = usage.cache_read_input_tokens || 0;

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
              const filePath = input.file_path || input.path || input.filePath;
              const oldString = input.old_str || input.old_string || input.oldStr || '';
              const newString = input.new_str || input.new_string || input.newStr || input.replacement || '';
              trackFile(filePath, countLines(newString), countLines(oldString));
            }

            if (/^MultiEdit$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              for (const edit of (input.edits || [])) {
                trackFile(filePath, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
              }
            }

            if (/^(write_file|Write|Create|file_write|create_file|write)$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              trackFile(filePath, countLines(input.content || input.file_text || ''), 0);
            }
          }
        }

        if (entry.type === 'tool_use' || entry.type === 'tool_call') {
          const name = entry.name || entry.tool_name || '';
          const input = entry.input || entry.args || {};

          if (/^(replace|Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
            const filePath = input.file_path || input.path || input.filePath;
            const oldString = input.old_str || input.old_string || input.oldStr || '';
            const newString = input.new_str || input.new_string || input.newStr || input.replacement || '';
            trackFile(filePath, countLines(newString), countLines(oldString));
          }

          if (/^MultiEdit$/i.test(name)) {
            const filePath = input.file_path || input.path || input.filePath;
            for (const edit of (input.edits || [])) {
              trackFile(filePath, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
            }
          }

          if (/^(write_file|Write|Create|file_write|create_file|write)$/i.test(name)) {
            const filePath = input.file_path || input.path || input.filePath;
            trackFile(filePath, countLines(input.content || input.file_text || ''), 0);
          }
        }
      } catch {}
    }

    const aiFiles = Object.entries(fileLineStats).map(([file, stats]) => ({
      file,
      ai_lines_added: stats.added,
      ai_lines_removed: stats.removed,
    }));

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
      'gemini-2.0-flash': { input: 0.10, output: 0.40, cache_read: 0.025, cache_creation: 0.10 },
    };
    const matchPricing = (modelName) => {
      const lower = modelName.toLowerCase();
      for (const [key, rates] of Object.entries(pricing)) {
        if (lower.includes(key)) return rates;
      }
      if (lower.includes('opus')) return pricing.opus;
      if (lower.includes('sonnet')) return pricing.sonnet;
      if (lower.includes('haiku')) return pricing.haiku;
      if (lower.includes('gemini') && lower.includes('flash')) return pricing['gemini-2.5-flash'];
      if (lower.includes('gemini')) return pricing['gemini-2.5-pro'];
      return pricing.sonnet;
    };

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

    return {
      session_id: sessionId,
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
      transcript_line_count: allLines.length,
    };
  }

  function parseCodexDelta(transcriptPath, lastLine, sessionId, model, cwd) {
    const allLines = fs.readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);
    if (allLines.length <= lastLine) {
      return { empty: true, transcript_line_count: allLines.length };
    }

    const repoRoot = (() => {
      try {
        return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
      } catch {
        return cwd || process.cwd();
      }
    })();

    let inputTokens = 0;
    let outputTokens = 0;
    let cacheCreation = 0;
    let cacheRead = 0;
    let turns = 0;
    let apiCalls = 0;
    const models = {};
    const fileLineStats = {};

    const trackFile = (filePath, added, removed) => {
      if (!filePath) return;
      let fp = String(filePath).replace(/^\.\//, '').replace(/^a\//, '').replace(/^b\//, '');
      if (fp.startsWith('/')) {
        if (!fp.startsWith(repoRoot + '/')) return;
        fp = fp.slice(repoRoot.length + 1);
      }
      if (fp.includes('node_modules') || fp.includes('.git/')) return;
      if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
      fileLineStats[fp].added += added;
      fileLineStats[fp].removed += removed;
    };

    const parsePatch = (patchText) => {
      if (!patchText) return;
      const patchLines = patchText.split('\n');
      let currentFile = null;
      let added = 0;
      let removed = 0;

      for (const line of patchLines) {
        const updateMatch = line.match(/^\*\*\* (?:Update File|Add File|Create File):\s*(.+)/);
        if (updateMatch) {
          if (currentFile) trackFile(currentFile, added, removed);
          currentFile = updateMatch[1].trim();
          added = 0;
          removed = 0;
          continue;
        }

        const diffAMatch = line.match(/^--- a\/(.+)/);
        if (diffAMatch && !line.startsWith('--- a/dev/null')) {
          if (currentFile) trackFile(currentFile, added, removed);
          currentFile = diffAMatch[1].trim();
          added = 0;
          removed = 0;
          continue;
        }

        if (line.startsWith('+') && !line.startsWith('+++')) added++;
        if (line.startsWith('-') && !line.startsWith('---')) removed++;
      }

      if (currentFile) trackFile(currentFile, added, removed);
    };

    let prevTokens = { input: 0, output: 0, cacheCreate: 0, cacheRead: 0, reasoning: 0 };

    for (let index = 0; index < allLines.length; index++) {
      try {
        const entry = JSON.parse(allLines[index]);
        const type = entry.type || '';
        const payload = entry.payload || entry;
        const inDelta = index >= lastLine;

        if (type === 'token_count' || payload.input_tokens != null) {
          const p = payload;
          const inp = (p.input_tokens || 0) - prevTokens.input;
          const out = (p.output_tokens || 0) - prevTokens.output;
          const cc = (p.cache_creation_tokens || 0) - prevTokens.cacheCreate;
          const cr = (p.cache_read_tokens || 0) - prevTokens.cacheRead;
          const rs = (p.reasoning_tokens || 0) - prevTokens.reasoning;

          prevTokens = {
            input: p.input_tokens || 0,
            output: p.output_tokens || 0,
            cacheCreate: p.cache_creation_tokens || 0,
            cacheRead: p.cache_read_tokens || 0,
            reasoning: p.reasoning_tokens || 0,
          };

          if (!inDelta) continue;
          if (inp > 0 || out > 0 || cc > 0 || cr > 0 || rs > 0) {
            inputTokens += Math.max(0, inp);
            outputTokens += Math.max(0, out);
            cacheCreation += Math.max(0, cc);
            cacheRead += Math.max(0, cr);
            apiCalls++;

            const modelName = entry.model || model || 'unknown';
            if (!models[modelName]) models[modelName] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
            models[modelName].input_tokens += Math.max(0, inp) + Math.max(0, cc) + Math.max(0, cr);
            models[modelName].output_tokens += Math.max(0, out);
            models[modelName].api_calls++;
          }
          continue;
        }

        if (!inDelta) continue;

        if (type === 'human' || type === 'user_message' || payload.role === 'user') turns++;

        const toolName = payload.tool || payload.tool_name || payload.name || '';
        const toolInput = payload.input || payload.tool_input || payload.arguments || {};
        if (/apply_patch/i.test(toolName)) {
          const patch = toolInput.patch || toolInput.input || toolInput.content || '';
          if (patch) parsePatch(patch);
        }

        const content = payload.content || (entry.message && entry.message.content) || [];
        if (Array.isArray(content)) {
          for (const block of content) {
            if ((block.type === 'tool_use' || block.name) && /apply_patch/i.test(block.name || '')) {
              const patch = (block.input || {}).patch || (block.input || {}).input || '';
              if (patch) parsePatch(patch);
            }
          }
        }
      } catch {}
    }

    const pricing = {
      'gpt-4': { input: 10, output: 30, cache_read: 1.0, cache_creation: 0 },
      'gpt-4o': { input: 2.5, output: 10, cache_read: 1.25, cache_creation: 0 },
      'gpt-4.1': { input: 2, output: 8, cache_read: 0.5, cache_creation: 0 },
      o1: { input: 15, output: 60, cache_read: 7.5, cache_creation: 0 },
      o3: { input: 10, output: 40, cache_read: 2.5, cache_creation: 0 },
      codex: { input: 2, output: 8, cache_read: 0.5, cache_creation: 0 },
    };
    const matchPricing = (modelName) => {
      const lower = (modelName || '').toLowerCase();
      if (lower.includes('o3')) return pricing.o3;
      if (lower.includes('o1')) return pricing.o1;
      if (lower.includes('gpt-4.1') || lower.includes('gpt4.1')) return pricing['gpt-4.1'];
      if (lower.includes('gpt-4o') || lower.includes('gpt4o')) return pricing['gpt-4o'];
      if (lower.includes('gpt-4') || lower.includes('gpt4')) return pricing['gpt-4'];
      return pricing.codex;
    };

    let estimatedCost = 0;
    for (const [modelName, info] of Object.entries(models)) {
      const rates = matchPricing(modelName);
      estimatedCost += (info.input_tokens / 1e6) * rates.input;
      estimatedCost += (info.output_tokens / 1e6) * rates.output;
    }
    const dominantModel = Object.keys(models).sort((a, b) =>
      (models[b].input_tokens + models[b].output_tokens) - (models[a].input_tokens + models[a].output_tokens),
    )[0] || model || '';
    const dominantRates = matchPricing(dominantModel);
    estimatedCost += (cacheRead / 1e6) * dominantRates.cache_read;

    return {
      session_id: sessionId,
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
      ai_files: Object.entries(fileLineStats).map(([file, stats]) => ({
        file,
        ai_lines_added: stats.added,
        ai_lines_removed: stats.removed,
      })),
      transcript_line_count: allLines.length,
    };
  }

  function parseWindsurfDelta(transcriptPath, lastLine, sessionId, cwd) {
    const allLines = fs.readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);
    const deltaLines = allLines.slice(lastLine);

    if (deltaLines.length === 0) {
      return { empty: true, transcript_line_count: allLines.length };
    }

    let inputTokens = 0;
    let outputTokens = 0;
    let cacheCreation = 0;
    let cacheRead = 0;
    let turns = 0;
    let apiCalls = 0;
    const models = {};
    const fileLineStats = {};

    const repoRoot = (() => {
      try {
        return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
      } catch {
        return cwd || process.cwd();
      }
    })();

    const trackFile = (filePath, added, removed) => {
      if (!filePath) return;
      let relativePath = filePath.replace(/^\.\//, '');

      if (relativePath.startsWith('/')) {
        if (relativePath.startsWith(repoRoot + '/')) relativePath = relativePath.slice(repoRoot.length + 1);
        else return;
      } else {
        const absolutePath = path.resolve(cwd || process.cwd(), relativePath);
        if (absolutePath.startsWith(repoRoot + '/')) relativePath = absolutePath.slice(repoRoot.length + 1);
      }

      if (relativePath.includes('.ai-stats') || relativePath.includes('node_modules')) return;
      if (!fileLineStats[relativePath]) fileLineStats[relativePath] = { added: 0, removed: 0 };
      fileLineStats[relativePath].added += added;
      fileLineStats[relativePath].removed += removed;
    };

    for (const line of deltaLines) {
      try {
        const entry = JSON.parse(line);

        if (entry.type === 'human' || entry.role === 'user') turns++;

        if (entry.type === 'assistant' || entry.role === 'assistant') {
          apiCalls++;
          const model = entry.model || entry.message?.model || '';
          if (model) {
            if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
            models[model].api_calls++;
          }
        }

        if (entry.message?.usage || entry.usage) {
          const usage = entry.message?.usage || entry.usage;
          const inp = usage.input_tokens || usage.prompt_tokens || 0;
          const out = usage.output_tokens || usage.completion_tokens || 0;
          inputTokens += inp;
          outputTokens += out;

          const model = entry.model || entry.message?.model || 'unknown';
          if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
          models[model].input_tokens += inp;
          models[model].output_tokens += out;
        }

        const content = entry.message?.content || entry.content;
        if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type !== 'tool_use') continue;
            const name = block.name || '';
            const input = block.input || {};

            if (/^(Edit|str_replace|str_replace_editor|edit|replace)$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              const oldString = input.old_str || input.old_string || input.oldStr || '';
              const newString = input.new_str || input.new_string || input.newStr || input.replacement || '';
              trackFile(filePath, countLines(newString), countLines(oldString));
            }

            if (/^MultiEdit$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              for (const edit of (input.edits || [])) {
                trackFile(filePath, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
              }
            }

            if (/^(Write|Create|file_write|create_file|write|write_file)$/i.test(name)) {
              const filePath = input.file_path || input.path || input.filePath;
              trackFile(filePath, countLines(input.content || input.file_text || ''), 0);
            }
          }
        }

        if (entry.type === 'tool_use' || entry.type === 'tool_call') {
          const name = entry.name || entry.tool_name || '';
          const input = entry.input || entry.args || {};

          if (/^(Edit|str_replace|str_replace_editor|edit|replace)$/i.test(name)) {
            const filePath = input.file_path || input.path || input.filePath;
            const oldString = input.old_str || input.old_string || input.oldStr || '';
            const newString = input.new_str || input.new_string || input.newStr || input.replacement || '';
            trackFile(filePath, countLines(newString), countLines(oldString));
          }

          if (/^MultiEdit$/i.test(name)) {
            const filePath = input.file_path || input.path || input.filePath;
            for (const edit of (input.edits || [])) {
              trackFile(filePath, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
            }
          }

          if (/^(Write|Create|file_write|create_file|write|write_file)$/i.test(name)) {
            const filePath = input.file_path || input.path || input.filePath;
            trackFile(filePath, countLines(input.content || input.file_text || ''), 0);
          }
        }
      } catch {}
    }

    const aiFiles = Object.entries(fileLineStats).map(([file, stats]) => ({
      file,
      ai_lines_added: stats.added,
      ai_lines_removed: stats.removed,
    }));

    return {
      session_id: sessionId,
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
      ai_files: aiFiles,
      transcript_line_count: allLines.length,
    };
  }

  function materializeActiveClaudeNote() {
    const active = readJson(activeFile);
    if (!active?.transcript_path) return false;
    if (!fs.existsSync(active.transcript_path)) {
      debug(`active transcript not found: ${active.transcript_path}`);
      return false;
    }

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(checkpointFile);
    const lastLine = checkpoint && checkpoint.transcript_path === active.transcript_path
      ? Number(checkpoint.last_line || 0)
      : 0;

    const stats = parseClaudeDelta(active.transcript_path, lastLine, active.session_id || 'unknown');
    writeCheckpoint(active.transcript_path, active.session_id || 'unknown', stats.transcript_line_count || lastLine);

    if (stats.empty) {
      debug('no new Claude delta for current commit');
      return false;
    }

    const hasContent = (stats.ai_files || []).length > 0 || ((stats.input_tokens || 0) + (stats.output_tokens || 0) > 0);
    if (!hasContent) {
      debug('current Claude delta had no file edits or token usage');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), stats);

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached Claude delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach Claude note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  function materializeActiveGeminiNote() {
    const active = readJson(geminiActiveFile);
    if (!active?.transcript_path) return false;
    if (!fs.existsSync(active.transcript_path)) {
      debug(`active Gemini transcript not found: ${active.transcript_path}`);
      return false;
    }

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(geminiCheckpointFile);
    const lastLine = checkpoint && checkpoint.transcript_path === active.transcript_path
      ? Number(checkpoint.last_line || 0)
      : 0;

    const stats = parseGeminiDelta(active.transcript_path, lastLine, active.session_id || 'unknown', active.cwd);
    writeGeminiCheckpoint(active.transcript_path, active.session_id || 'unknown', stats.transcript_line_count || lastLine);

    if (stats.empty) {
      debug('no new Gemini delta for current commit');
      return false;
    }

    const hasContent = (stats.ai_files || []).length > 0 || ((stats.input_tokens || 0) + (stats.output_tokens || 0) > 0);
    if (!hasContent) {
      debug('current Gemini delta had no file edits or token usage');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), stats);

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached Gemini delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach Gemini note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  function materializeActiveCodexNote() {
    const active = readJson(codexActiveFile);
    if (!active?.transcript_path) return false;
    if (!fs.existsSync(active.transcript_path)) {
      debug(`active Codex transcript not found: ${active.transcript_path}`);
      return false;
    }

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(codexCheckpointFile);
    const lastLine = checkpoint && checkpoint.transcript_path === active.transcript_path
      ? Number(checkpoint.last_line || 0)
      : 0;

    const stats = parseCodexDelta(active.transcript_path, lastLine, active.session_id || 'unknown', active.model || '', active.cwd);
    writeCodexCheckpoint(active.transcript_path, active.session_id || 'unknown', stats.transcript_line_count || lastLine);

    if (stats.empty) {
      debug('no new Codex delta for current commit');
      return false;
    }

    const hasContent = (stats.ai_files || []).length > 0 || ((stats.input_tokens || 0) + (stats.output_tokens || 0) > 0);
    if (!hasContent) {
      debug('current Codex delta had no file edits or token usage');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), stats);

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached Codex delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach Codex note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  function materializeActiveWindsurfNote() {
    const active = readJson(windsurfActiveFile);
    if (!active?.transcript_path) return false;
    if (!fs.existsSync(active.transcript_path)) {
      debug(`active Windsurf transcript not found: ${active.transcript_path}`);
      return false;
    }

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(windsurfCheckpointFile);
    const lastLine = checkpoint && checkpoint.transcript_path === active.transcript_path
      ? Number(checkpoint.last_line || 0)
      : 0;

    const stats = parseWindsurfDelta(active.transcript_path, lastLine, active.session_id || 'unknown', active.cwd);
    writeWindsurfCheckpoint(active.transcript_path, active.session_id || 'unknown', stats.transcript_line_count || lastLine);

    if (stats.empty) {
      debug('no new Windsurf delta for current commit');
      return false;
    }

    const hasContent = (stats.ai_files || []).length > 0 || ((stats.input_tokens || 0) + (stats.output_tokens || 0) > 0);
    if (!hasContent) {
      debug('current Windsurf delta had no file edits or token usage');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), stats);

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached Windsurf delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach Windsurf note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  function materializeCopilotPendingNote() {
    const active = readJson(copilotActiveFile);
    const pending = readJson(copilotPendingFile);
    if (!active?.cwd || !pending || Object.keys(pending).length === 0) return false;

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(copilotCheckpointFile);
    const previousFiles = checkpoint && checkpoint.cwd === active.cwd ? (checkpoint.files || {}) : {};
    const deltaFiles = fileDelta(pending, previousFiles);

    writeCopilotCheckpoint(active.cwd, pending);

    if (Object.keys(deltaFiles).length === 0) {
      debug('no new Copilot delta for current commit');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), {
      ai_files: Object.entries(deltaFiles).map(([file, stats]) => ({
        file,
        ai_lines_added: stats.added || 0,
        ai_lines_removed: stats.removed || 0,
      })),
    });

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached Copilot delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach Copilot note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  function materializeAugmentPendingNote() {
    const active = readJson(augmentActiveFile);
    const pending = readJson(augmentPendingFile);
    if (!active?.cwd || !pending || Object.keys(pending).length === 0) return false;

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(augmentCheckpointFile);
    const previousFiles = checkpoint && checkpoint.cwd === active.cwd ? (checkpoint.files || {}) : {};
    const deltaFiles = fileDelta(pending, previousFiles);

    writeAugmentCheckpoint(active.cwd, pending);

    if (Object.keys(deltaFiles).length === 0) {
      debug('no new Augment delta for current commit');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), {
      ai_files: Object.entries(deltaFiles).map(([file, stats]) => ({
        file,
        ai_lines_added: stats.added || 0,
        ai_lines_removed: stats.removed || 0,
      })),
    });

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached Augment delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach Augment note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  function materializeOpencodePendingNote() {
    const active = readJson(opencodeActiveFile);
    const pending = readJson(opencodePendingFile);
    if (!active?.cwd || !pending || Object.keys(pending).length === 0) return false;

    let headSha;
    try {
      headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    } catch {
      return false;
    }

    const checkpoint = readJson(opencodeCheckpointFile);
    const previousFiles = checkpoint && checkpoint.cwd === active.cwd ? (checkpoint.files || {}) : {};
    const deltaFiles = fileDelta(pending, previousFiles);

    writeOpencodeCheckpoint(active.cwd, pending);

    if (Object.keys(deltaFiles).length === 0) {
      debug('no new OpenCode delta for current commit');
      return false;
    }

    const merged = mergeNote(readGitNote(headSha), {
      ai_files: Object.entries(deltaFiles).map(([file, stats]) => ({
        file,
        ai_lines_added: stats.added || 0,
        ai_lines_removed: stats.removed || 0,
      })),
    });

    try {
      execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
        input: merged,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      debug(`attached OpenCode delta note to ${headSha}`);
      pushNotesRef();
      return true;
    } catch (error) {
      process.stderr.write(`[gitprint] failed to attach OpenCode note to ${headSha}: ${error.message}\n`);
      return false;
    }
  }

  materializeActiveClaudeNote();
  materializeActiveGeminiNote();
  materializeActiveCodexNote();
  materializeActiveWindsurfNote();
  materializeCopilotPendingNote();
  materializeAugmentPendingNote();
  materializeOpencodePendingNote();

  const protectedBranches = new Set(['main', 'master', 'develop', 'staging', 'pre_release_master']);
  if (!platformUrl || !platformToken) {
    debug('missing platform URL or token — skipping platform ingest');
    return;
  }
  if (!branch) {
    debug('detached HEAD — skipping platform ingest');
    return;
  }
  if (protectedBranches.has(branch)) {
    debug(`on base branch ${branch} — skipping platform ingest`);
    return;
  }

  function postToPlatform(url, token, body) {
    return new Promise((resolve) => {
      const data = JSON.stringify(body);
      let parsed;
      try {
        parsed = new URL(url + '/api/ingest/push');
      } catch {
        process.stderr.write('[gitprint] invalid platform URL\n');
        return resolve(false);
      }

      const mod = parsed.protocol === 'https:' ? https : http;
      const req = mod.request({
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
        path: parsed.pathname + (parsed.search || ''),
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Content-Length': Buffer.byteLength(data),
        },
      }, (res) => {
        let body = '';
        res.on('data', (chunk) => body += chunk);
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(true);
          } else {
            process.stderr.write(`[gitprint] platform responded ${res.statusCode}: ${body}\n`);
            resolve(false);
          }
        });
      });

      req.on('error', (error) => {
        process.stderr.write(`[gitprint] platform POST failed: ${error.message}\n`);
        resolve(false);
      });
      req.setTimeout(15000, () => { req.destroy(); resolve(false); });
      req.write(data);
      req.end();
    });
  }

  if (fs.existsSync(outboxFile)) {
    const lines = fs.readFileSync(outboxFile, 'utf8').split('\n').filter(Boolean);
    const remaining = [];
    for (const line of lines) {
      try {
        const payload = JSON.parse(line);
        const ok = await postToPlatform(platformUrl, platformToken, payload);
        if (!ok) remaining.push(line);
      } catch {
        remaining.push(line);
      }
    }

    if (remaining.length > 0) fs.writeFileSync(outboxFile, remaining.join('\n') + '\n');
    else {
      try { fs.unlinkSync(outboxFile); } catch {}
    }
  }

  let commitLog;
  try {
    commitLog = execSync(`git log origin/${base}..HEAD --format="%H|||%s|||%an|||%aI" 2>/dev/null`, { encoding: 'utf8' })
      .trim().split('\n').filter(Boolean);
  } catch {
    try {
      commitLog = execSync('git log --format="%H|||%s|||%an|||%aI"', { encoding: 'utf8' })
        .trim().split('\n').filter(Boolean).slice(0, 20);
    } catch {
      process.exit(0);
    }
  }
  if (commitLog.length === 0) process.exit(0);

  const commits = commitLog.map((line) => {
    const [sha, message, author, timestamp] = line.split('|||');
    return {
      sha,
      message: message || '',
      author: author || sender,
      timestamp: timestamp || new Date().toISOString(),
    };
  });

  const allSessions = [];
  const allFileStats = {};
  const aiCommitShas = new Set();
  const perCommitNotes = {};

  for (const { sha } of commits) {
    try {
      const note = readGitNote(sha);
      if (!note || note === '{}') continue;
      const data = JSON.parse(note);
      if ((data.sessions || []).length > 0) aiCommitShas.add(sha);
      perCommitNotes[sha] = data;

      for (const session of (data.sessions || [])) {
        const existingIndex = allSessions.findIndex((entry) => entry.session_id === session.session_id);
        if (existingIndex === -1) {
          allSessions.push({ ...session });
        } else {
          mergeSession(allSessions[existingIndex], session);
        }
      }

      for (const file of (data.ai_files || [])) {
        if (!allFileStats[file.file]) {
          allFileStats[file.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
        }
        allFileStats[file.file].ai_lines_added += file.ai_lines_added || 0;
        allFileStats[file.file].ai_lines_removed += file.ai_lines_removed || 0;
      }
    } catch {}
  }

  if (allSessions.length === 0 && Object.keys(allFileStats).length === 0) process.exit(0);

  const pricing = {
    opus: { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
    sonnet: { input: 3, output: 15, cache_read: 0.30, cache_creation: 3.75 },
    haiku: { input: 1, output: 5, cache_read: 0.10, cache_creation: 1.25 },
  };
  const matchPricing = (model) => {
    const lower = (model || '').toLowerCase();
    if (lower.includes('opus')) return pricing.opus;
    if (lower.includes('sonnet')) return pricing.sonnet;
    if (lower.includes('haiku')) return pricing.haiku;
    return pricing.sonnet;
  };

  let totalCost = 0;
  for (const session of allSessions) {
    if (session.estimated_cost != null) {
      totalCost += session.estimated_cost;
      continue;
    }
    for (const [model, info] of Object.entries(session.models || {})) {
      const rates = matchPricing(model);
      totalCost += (info.input_tokens / 1e6) * rates.input;
      totalCost += (info.output_tokens / 1e6) * rates.output;
    }
    const dominantModel = Object.keys(session.models || {})[0] || '';
    const dominantRates = matchPricing(dominantModel);
    totalCost += ((session.cache_creation_tokens || 0) / 1e6) * dominantRates.cache_creation;
    totalCost += ((session.cache_read_tokens || 0) / 1e6) * dominantRates.cache_read;
  }

  const totalTokens = allSessions.reduce((sum, session) =>
    sum
      + (session.input_tokens || 0)
      + (session.output_tokens || 0)
      + (session.cache_creation_tokens || 0)
      + (session.cache_read_tokens || 0), 0);

  const EXCLUDE = [/^\.claude\//, /^\.github\//, /^\.gitprint\//, /^\.cursor\//, /^\.vscode\//, /^\.idea\//];
  const isExcluded = (file) => EXCLUDE.some((pattern) => pattern.test(file));

  let diffOutput = '';
  try {
    diffOutput = execSync(`git diff --numstat origin/${base}...HEAD 2>/dev/null`, { encoding: 'utf8' });
  } catch {
    try {
      diffOutput = execSync('git diff --numstat HEAD^ HEAD 2>/dev/null', { encoding: 'utf8' });
    } catch {}
  }

  const files = [];
  diffOutput.split('\n').filter(Boolean).forEach((line) => {
    const [added, removed, file] = line.split('\t');
    if (!file || isExcluded(file)) return;

    const linesAdded = parseInt(added, 10) || 0;
    const linesRemoved = parseInt(removed, 10) || 0;
    const totalFileLines = linesAdded + linesRemoved;

    let aiStat = allFileStats[file];
    if (!aiStat) {
      const match = Object.keys(allFileStats).find((candidate) => file.endsWith('/' + candidate) || candidate.endsWith('/' + file));
      if (match) aiStat = allFileStats[match];
    }

    const aiLines = aiStat
      ? Math.min((aiStat.ai_lines_added || 0) + (aiStat.ai_lines_removed || 0), totalFileLines)
      : 0;

    files.push({
      file,
      total_added: linesAdded,
      total_removed: linesRemoved,
      ai_lines_added: aiLines,
      ai_lines_removed: 0,
      human_lines_added: Math.max(0, linesAdded - aiLines),
      human_lines_removed: 0,
    });
  });

  const commitDetails = commits.map((commit) => {
    const note = perCommitNotes[commit.sha];
    const commitAiFiles = note ? (note.ai_files || []) : [];
    const commitFiles = [];

    try {
      const commitDiff = execSync(`git diff --numstat ${commit.sha}^..${commit.sha} 2>/dev/null`, { encoding: 'utf8' });
      commitDiff.split('\n').filter(Boolean).forEach((line) => {
        const [added, removed, file] = line.split('\t');
        if (!file || isExcluded(file)) return;

        const linesAdded = parseInt(added, 10) || 0;
        const linesRemoved = parseInt(removed, 10) || 0;
        const aiFile = commitAiFiles.find((entry) => entry.file === file)
          || commitAiFiles.find((entry) => file.endsWith('/' + entry.file) || entry.file.endsWith('/' + file));
        const aiLines = aiFile
          ? Math.min((aiFile.ai_lines_added || 0) + (aiFile.ai_lines_removed || 0), linesAdded + linesRemoved)
          : 0;

        commitFiles.push({
          file,
          total_added: linesAdded,
          total_removed: linesRemoved,
          ai_lines_added: aiLines,
          ai_lines_removed: 0,
        });
      });
    } catch {}

    return {
      sha: commit.sha,
      message: commit.message,
      author: commit.author,
      timestamp: commit.timestamp,
      hasAi: aiCommitShas.has(commit.sha),
      files: commitFiles,
    };
  });

  const tools = [...new Set(allSessions.map((session) => session.tool || 'claude-code').filter(Boolean))];
  const payload = { repo, branch, sender, sessions: allSessions, files, commits: commitDetails, totalCost, totalTokens, tools };

  const ok = await postToPlatform(platformUrl, platformToken, payload);
  if (!ok) {
    fs.appendFileSync(outboxFile, JSON.stringify(payload) + '\n');
    process.stderr.write('[gitprint] ingest queued (.git/gitprint-outbox.jsonl) — will retry on next commit\n');
  }
})().catch((error) => {
  process.stderr.write(`[gitprint] post-commit error: ${error.message}\n`);
});
NODEEOF

exit 0
