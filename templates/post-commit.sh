#!/bin/bash
# Gitprint — Post-Commit Hook
# Fires after every git commit. Reads local notes, calculates AI stats, POSTs to platform.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint] $*" >&2; }
log_err() { echo "[gitprint] ERROR: $*" >&2; }

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
CONFIG_FILE="$GIT_DIR/gitprint-config"

[ -f "$CONFIG_FILE" ] || { log "no gitprint-config — skipping platform ingest"; exit 0; }

PLATFORM_URL=$(grep '^AI_PLATFORM_URL=' "$CONFIG_FILE" | cut -d= -f2-)
PLATFORM_TOKEN=$(grep '^AI_PLATFORM_TOKEN=' "$CONFIG_FILE" | cut -d= -f2-)

[ -n "$PLATFORM_URL" ] && [ -n "$PLATFORM_TOKEN" ] || { log "missing platform URL or token — skipping"; exit 0; }

CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null) || { log "detached HEAD — skipping"; exit 0; }

case "$CURRENT_BRANCH" in
  main|master|develop|staging|pre_release_master)
    log "on base branch $CURRENT_BRANCH — skipping"
    exit 0
    ;;
esac

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo '')
REPO=$(echo "$REMOTE_URL" | sed 's|.*github\.com[:/]||' | sed 's|\.git$||')
SENDER_EMAIL=$(git config user.email 2>/dev/null || echo '')
SENDER_NAME=$(git config user.name 2>/dev/null || echo '')
SENDER="${SENDER_EMAIL:-${SENDER_NAME:-unknown}}"

log "post-commit: branch=$CURRENT_BRANCH repo=$REPO sender=$SENDER"

node - "$PLATFORM_URL" "$PLATFORM_TOKEN" "$CURRENT_BRANCH" "$REPO" "$SENDER" "$GIT_DIR" "$SENDER_EMAIL" "$SENDER_NAME" << 'NODEEOF'
(async () => {
  const { execSync } = require('child_process');
  const fs = require('fs');
  const https = require('https');
  const http = require('http');

  const debug = process.env.GITPRINT_DEBUG === '1';
  const [platformUrl, platformToken, branch, repo, sender, gitDir, senderEmail, senderName] = process.argv.slice(2);
  const logFile = require('path').join(gitDir, 'gitprint-post-commit.log');
  const outboxFile = require('path').join(gitDir, 'gitprint-outbox.jsonl');

  let headCommit = { sha: '', message: '' };
  try {
    const raw = execSync('git log -1 --format="%H|||%s"', { encoding: 'utf8' }).trim();
    const [sha, message] = raw.split('|||');
    headCommit = { sha: sha || '', message: message || '' };
  } catch {}

  const appendLog = (entry) => {
    try {
      fs.appendFileSync(logFile, JSON.stringify({ ts: new Date().toISOString(), commit: headCommit.sha, message: headCommit.message, ...entry }) + '\n');
    } catch {}
  };
  const log = (...a) => debug && process.stderr.write('[gitprint:node] ' + a.join(' ') + '\n');

  log(`platformUrl=${platformUrl} branch=${branch} repo=${repo}`);

  // ─── POST helper ───
  function postToPlatform(url, token, body) {
    return new Promise((resolve) => {
      const data = JSON.stringify(body);
      let parsed;
      try { parsed = new URL(url + '/api/ingest/push'); } catch {
        appendLog({ event: 'post_error', reason: 'invalid platform URL', url });
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
          'Authorization': `Bearer ${token}`,
          'Content-Length': Buffer.byteLength(data),
        },
      }, (res) => {
        let body = '';
        res.on('data', d => body += d);
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            appendLog({ event: 'post_ok', status: res.statusCode, repo, branch });
            resolve(true);
          } else {
            appendLog({ event: 'post_failed', status: res.statusCode, response: body.slice(0, 500) });
            process.stderr.write(`[gitprint] platform responded ${res.statusCode}: ${body}\n`);
            resolve(false);
          }
        });
      });
      req.on('error', (e) => {
        appendLog({ event: 'post_error', reason: e.message });
        process.stderr.write(`[gitprint] platform POST failed: ${e.message}\n`);
        resolve(false);
      });
      req.setTimeout(15000, () => { req.destroy(); appendLog({ event: 'post_timeout' }); resolve(false); });
      req.write(data);
      req.end();
    });
  }

  // ─── Retry outbox ───
  if (fs.existsSync(outboxFile)) {
    const lines = fs.readFileSync(outboxFile, 'utf8').split('\n').filter(Boolean);
    const remaining = [];
    for (const line of lines) {
      try {
        const payload = JSON.parse(line);
        const ok = await postToPlatform(platformUrl, platformToken, payload);
        if (!ok) remaining.push(line);
      } catch { remaining.push(line); }
    }
    if (remaining.length > 0) {
      fs.writeFileSync(outboxFile, remaining.join('\n') + '\n');
    } else {
      try { fs.unlinkSync(outboxFile); } catch {}
    }
  }

  // ─── Parse transcript delta → write note on new HEAD ───
  // post-tool-use.sh only writes active.json (transcript pointer).
  // We parse here so the note lands on the new commit SHA, not the old HEAD.
  const activeFile = require('path').join(gitDir, 'gitprint-active.json');
  const checkpointFile = require('path').join(gitDir, 'gitprint-checkpoint.json');
  try {
    if (!fs.existsSync(activeFile)) {
      appendLog({ event: 'transcript_skip', reason: 'active.json not found — post-tool-use hook may not have fired' });
    } else {
      const active = JSON.parse(fs.readFileSync(activeFile, 'utf8'));
      const tp = active.transcript_path;
      appendLog({ event: 'transcript_found', transcript_path: tp, session_id: active.session_id, repo, branch });
    }
    if (fs.existsSync(activeFile)) {
      const active = JSON.parse(fs.readFileSync(activeFile, 'utf8'));
      const tp = active.transcript_path;
      if (tp && fs.existsSync(tp)) {
        let lastLine = 0;
        try {
          const cp = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
          if (cp.transcript_path === tp) lastLine = cp.last_line || 0;
        } catch {}

        const all = fs.readFileSync(tp, 'utf8').split('\n').filter(Boolean);
        const delta = all.slice(lastLine);
        log(`transcript delta: ${delta.length} new lines from offset ${lastLine}`);

        if (delta.length > 0) {
          let inp = 0, out = 0, cc = 0, cr = 0, turns = 0, apiCalls = 0;
          const models = {};
          const fileLineStats = {};
          const repoRoot = (() => { try { return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim(); } catch { return process.cwd(); } })();
          const countLines = (s) => !s ? 0 : String(s).split('\n').length;
          const trackFile = (fp, added, removed) => {
            if (!fp) return;
            fp = fp.replace(/^\.\//, '');
            if (fp.startsWith('/')) {
              if (fp.startsWith(repoRoot + '/')) fp = fp.slice(repoRoot.length + 1); else return;
            } else {
              const abs = require('path').resolve(process.cwd(), fp);
              if (abs.startsWith(repoRoot + '/')) fp = abs.slice(repoRoot.length + 1);
            }
            const SETUP_EXCLUDE = [/^\.claude\//, /^\.github\//, /^\.gitprint\//, /^\.cursor\//, /^\.gemini\//, /^\.windsurf\//, /^\.augment\//, /^\.codex\//, /^\.opencode\//, /node_modules/];
            if (SETUP_EXCLUDE.some(p => p.test(fp))) return;
            if (!fileLineStats[fp]) fileLineStats[fp] = { added: 0, removed: 0 };
            fileLineStats[fp].added += added;
            fileLineStats[fp].removed += removed;
          };

          for (const line of delta) {
            try {
              const e = JSON.parse(line);
              if (e.isSidechain || e.isApiErrorMessage) continue;
              if (e.type === 'human') turns++;
              if (e.type === 'assistant' && e.message?.usage) {
                const u = e.message.usage;
                const i = u.input_tokens || 0, o = u.output_tokens || 0;
                const c = u.cache_creation_input_tokens || 0, r = u.cache_read_input_tokens || 0;
                inp += i; out += o; cc += c; cr += r; apiCalls++;
                const m = e.model || e.message?.model || 'unknown';
                if (!models[m]) models[m] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
                models[m].input_tokens += i + c + r;
                models[m].output_tokens += o;
                models[m].api_calls++;
              }
              if (e.type === 'assistant' && e.message?.content) {
                for (const block of e.message.content) {
                  if (block.type !== 'tool_use') continue;
                  const name = block.name || '', input = block.input || {};
                  if (/^(Edit|str_replace|str_replace_editor|edit)$/i.test(name)) {
                    trackFile(input.file_path || input.path, countLines(input.new_str || input.new_string || input.replacement || ''), countLines(input.old_str || input.old_string || ''));
                  }
                  if (/^MultiEdit$/i.test(name)) {
                    for (const ed of (input.edits || [])) trackFile(input.file_path || input.path, countLines(ed.new_str || ed.new_string || ''), countLines(ed.old_str || ed.old_string || ''));
                  }
                  if (/^(Write|Create|file_write|create_file|write)$/i.test(name)) {
                    trackFile(input.file_path || input.path, countLines(input.content || input.file_text || ''), 0);
                  }
                }
              }
            } catch {}
          }

          appendLog({ event: 'transcript_parsed', delta_lines: delta.length, from_line: lastLine, total_lines: all.length, inp, out, cc, cr, api_calls: apiCalls, files: Object.keys(fileLineStats).length, repo, branch });
          const hasContent = (inp + out + cc + cr) > 0 || Object.keys(fileLineStats).length > 0;
          if (!hasContent) appendLog({ event: 'transcript_empty', reason: 'delta had no token usage or file edits', repo, branch });
          if (hasContent) {
            // Cost
            const pricing = { opus: { input:15, output:75, cache_read:1.5, cache_creation:18.75 }, sonnet: { input:3, output:15, cache_read:0.3, cache_creation:3.75 }, haiku: { input:1, output:5, cache_read:0.1, cache_creation:1.25 } };
            const matchP = (m) => { const ml=(m||'').toLowerCase(); if(ml.includes('opus')) return pricing.opus; if(ml.includes('haiku')) return pricing.haiku; return pricing.sonnet; };
            let cost = 0;
            for (const [m, info] of Object.entries(models)) { const p=matchP(m); cost += (info.input_tokens/1e6)*p.input + (info.output_tokens/1e6)*p.output; }
            const dom = Object.keys(models).sort((a,b)=>(models[b].input_tokens+models[b].output_tokens)-(models[a].input_tokens+models[a].output_tokens))[0]||'';
            const dp = matchP(dom);
            cost += (cc/1e6)*dp.cache_creation + (cr/1e6)*dp.cache_read;

            const headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
            const note = { sessions: [], ai_files: [] };
            const sid = active.session_id || 'unknown';
            note.sessions.push({ session_id: sid, tool: 'claude-code', timestamp: new Date().toISOString(), input_tokens: inp, output_tokens: out, cache_creation_tokens: cc, cache_read_tokens: cr, estimated_cost: Math.round(cost*10000)/10000, turns, api_calls: apiCalls, models });
            note.ai_files = Object.entries(fileLineStats).map(([file, s]) => ({ file, ai_lines_added: s.added, ai_lines_removed: s.removed }));

            execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`,
              { input: JSON.stringify(note), stdio: ['pipe', 'ignore', 'pipe'] });
            log(`transcript parsed: ${note.sessions[0].api_calls} api calls, ${note.ai_files.length} files → note on ${headSha}`);
          }

          // Advance checkpoint so next commit only parses new lines
          fs.writeFileSync(checkpointFile, JSON.stringify({ transcript_path: tp, last_line: all.length }));
        }
      }
    }
  } catch (e) { log(`transcript parse failed: ${e.message}`); }

  // ─── Get HEAD commit only ───
  let commitLog;
  try {
    commitLog = execSync(`git log -1 --format="%H|||%s|||%an|||%ae|||%aI"`, { encoding: 'utf8' })
      .trim().split('\n').filter(Boolean);
  } catch { process.exit(0); }
  log(`found ${commitLog.length} commits`);
  if (commitLog.length === 0) process.exit(0);

  const commits = commitLog.map(l => {
    const [sha, message, authorName, authorEmail, timestamp] = l.split('|||');
    return {
      sha,
      message: message || '',
      author: authorName || sender,
      author_name: authorName || '',
      author_email: authorEmail || '',
      timestamp: timestamp || new Date().toISOString(),
    };
  });

  // ─── Read notes, aggregate sessions + file stats ───
  const allSessions = [];
  const allFileStats = {};
  const aiCommitShas = new Set();
  const perCommitNotes = {};

  for (const { sha } of commits) {
    try {
      const note = execSync(`git notes --ref=gitprint show ${sha} 2>/dev/null`, { encoding: 'utf8' }).trim();
      if (!note) continue;
      const data = JSON.parse(note);
      if ((data.sessions || []).length > 0) aiCommitShas.add(sha);
      perCommitNotes[sha] = data;

      for (const s of (data.sessions || [])) {
        const idx = allSessions.findIndex(x => x.session_id === s.session_id);
        if (idx === -1) {
          allSessions.push({ ...s });
        } else {
          const ex = allSessions[idx];
          ex.input_tokens = (ex.input_tokens || 0) + (s.input_tokens || 0);
          ex.output_tokens = (ex.output_tokens || 0) + (s.output_tokens || 0);
          ex.cache_creation_tokens = (ex.cache_creation_tokens || 0) + (s.cache_creation_tokens || 0);
          ex.cache_read_tokens = (ex.cache_read_tokens || 0) + (s.cache_read_tokens || 0);
          ex.estimated_cost = (ex.estimated_cost || 0) + (s.estimated_cost || 0);
          ex.turns = (ex.turns || 0) + (s.turns || 0);
          ex.api_calls = (ex.api_calls || 0) + (s.api_calls || 0);
          for (const [model, info] of Object.entries(s.models || {})) {
            if (!ex.models) ex.models = {};
            if (!ex.models[model]) ex.models[model] = { input_tokens: 0, output_tokens: 0, api_calls: 0 };
            ex.models[model].input_tokens += info.input_tokens || 0;
            ex.models[model].output_tokens += info.output_tokens || 0;
            ex.models[model].api_calls = (ex.models[model].api_calls || 0) + (info.api_calls || 0);
          }
        }
      }

      for (const f of (data.ai_files || [])) {
        if (!allFileStats[f.file]) allFileStats[f.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
        allFileStats[f.file].ai_lines_added += f.ai_lines_added || 0;
        allFileStats[f.file].ai_lines_removed += f.ai_lines_removed || 0;
      }
    } catch {}
  }

  log(`sessions=${allSessions.length} fileStats=${Object.keys(allFileStats).length}`);

  // ─── Cost ───
  const pricing = {
    'opus':   { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
    'sonnet': { input: 3,  output: 15, cache_read: 0.30, cache_creation: 3.75 },
    'haiku':  { input: 1,  output: 5,  cache_read: 0.10, cache_creation: 1.25 },
  };
  const matchPricing = (m) => {
    const ml = (m || '').toLowerCase();
    if (ml.includes('opus')) return pricing.opus;
    if (ml.includes('sonnet')) return pricing.sonnet;
    if (ml.includes('haiku')) return pricing.haiku;
    return pricing.sonnet;
  };

  let totalCost = 0;
  for (const s of allSessions) {
    if (s.estimated_cost != null) { totalCost += s.estimated_cost; continue; }
    for (const [model, info] of Object.entries(s.models || {})) {
      const p = matchPricing(model);
      totalCost += (info.input_tokens / 1e6) * p.input;
      totalCost += (info.output_tokens / 1e6) * p.output;
    }
    const cc = s.cache_creation_tokens || 0;
    const cr = s.cache_read_tokens || 0;
    const dm = Object.keys(s.models || {})[0] || '';
    const dp = matchPricing(dm);
    totalCost += (cc / 1e6) * dp.cache_creation;
    totalCost += (cr / 1e6) * dp.cache_read;
  }

  const totalTokens = allSessions.reduce((acc, s) =>
    acc + (s.input_tokens||0) + (s.output_tokens||0) + (s.cache_creation_tokens||0) + (s.cache_read_tokens||0), 0);

  // ─── Diff reconciliation ───
  const EXCLUDE = [/^\.claude\//, /^\.github\//, /^\.gitprint\//, /^\.cursor\//, /^\.gemini\//, /^\.windsurf\//, /^\.augment\//, /^\.codex\//, /^\.opencode\//, /^\.vscode\//, /^\.idea\//, /node_modules/];
  const isExcluded = (f) => EXCLUDE.some(p => p.test(f));

  let diffOutput = '';
  try { diffOutput = execSync(`git diff --numstat HEAD^ HEAD 2>/dev/null`, { encoding: 'utf8' }); } catch {}

  const files = [];
  diffOutput.split('\n').filter(Boolean).forEach(line => {
    const [added, removed, file] = line.split('\t');
    if (!file || isExcluded(file)) return;
    const linesAdded = parseInt(added) || 0;
    const linesRemoved = parseInt(removed) || 0;
    const totalFileLines = linesAdded + linesRemoved;

    let aiStat = allFileStats[file];
    if (!aiStat) {
      const match = Object.keys(allFileStats).find(k => file.endsWith('/' + k) || k.endsWith('/' + file));
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

  // ─── Per-commit file breakdown ───
  const commitDetails = commits.map(c => {
    const note = perCommitNotes[c.sha];
    const commitAiFiles = note ? (note.ai_files || []) : [];
    const commitFiles = [];
    try {
      const cdiff = execSync(`git diff --numstat ${c.sha}^..${c.sha} 2>/dev/null`, { encoding: 'utf8' });
      cdiff.split('\n').filter(Boolean).forEach(line => {
        const [added, removed, file] = line.split('\t');
        if (!file || isExcluded(file)) return;
        const linesAdded = parseInt(added) || 0;
        const linesRemoved = parseInt(removed) || 0;
        const aiFile = commitAiFiles.find(f => f.file === file)
          || commitAiFiles.find(f => file.endsWith('/' + f.file) || f.file.endsWith('/' + file));
        const aiLines = aiFile
          ? Math.min((aiFile.ai_lines_added||0) + (aiFile.ai_lines_removed||0), linesAdded + linesRemoved)
          : 0;
        commitFiles.push({ file, total_added: linesAdded, total_removed: linesRemoved, ai_lines_added: aiLines, ai_lines_removed: 0 });
      });
    } catch {}
    return {
      sha: c.sha,
      message: c.message,
      author: c.author,
      timestamp: c.timestamp,
      hasAi: aiCommitShas.has(c.sha),
      files: commitFiles,
      author_name: c.author_name,
      author_email: c.author_email,
    };
  });

  // ─── Build + POST payload ───
  const tools = [...new Set(allSessions.map(s => s.tool || 'claude-code').filter(Boolean))];
  const headSha = commits[0]?.sha || '';
  const payload = {
    repo, branch, sender,
    sender_email: senderEmail || '',
    sender_name: senderName || '',
    note_commit_sha: headSha,
    sessions: allSessions, files, commits: commitDetails, totalCost, totalTokens, tools,
  };

  appendLog({
    event: 'posting',
    repo, branch, commit: headSha,
    sessions: allSessions.length,
    files: files.length,
    totalCost, totalTokens, tools,
    note: { sessions: allSessions, ai_files: Object.entries(allFileStats).map(([file, s]) => ({ file, ...s })) },
  });

  const ok = await postToPlatform(platformUrl, platformToken, payload);
  if (!ok) {
    fs.appendFileSync(outboxFile, JSON.stringify(payload) + '\n');
    process.stderr.write('[gitprint] ingest queued (.git/gitprint-outbox.jsonl) — will retry on next commit\n');
  } else {
    // ─── Cleanup: remove note (saves space), reset checkpoint, drop active marker ───
    const sha = commits[0]?.sha;
    if (sha) {
      try { execSync(`git notes --ref=gitprint remove ${sha} 2>/dev/null`, { stdio: 'pipe' }); } catch {}
    }
    try { fs.unlinkSync(checkpointFile); } catch {}
    try { fs.unlinkSync(activeFile); } catch {}
    log('post-POST cleanup: note removed, checkpoint + active.json cleared');
  }

})().catch((e) => {
  process.stderr.write(`[gitprint] post-commit error: ${e.message}\n`);
});
NODEEOF

exit 0
