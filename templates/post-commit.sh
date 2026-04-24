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
SENDER=$(git config user.email 2>/dev/null || git config user.name 2>/dev/null || echo 'unknown')

log "post-commit: branch=$CURRENT_BRANCH repo=$REPO sender=$SENDER"

node - "$PLATFORM_URL" "$PLATFORM_TOKEN" "$CURRENT_BRANCH" "$REPO" "$SENDER" "$GIT_DIR" << 'NODEEOF'
(async () => {
  const { execSync } = require('child_process');
  const fs = require('fs');
  const https = require('https');
  const http = require('http');

  const debug = process.env.GITPRINT_DEBUG === '1';
  const log = (...a) => debug && process.stderr.write('[gitprint:node] ' + a.join(' ') + '\n');

  const [platformUrl, platformToken, branch, repo, sender, gitDir] = process.argv.slice(2);
  log(`platformUrl=${platformUrl} branch=${branch} repo=${repo}`);
  const outboxFile = require('path').join(gitDir, 'gitprint-outbox.jsonl');

  // ─── POST helper ───
  function postToPlatform(url, token, body) {
    return new Promise((resolve) => {
      const data = JSON.stringify(body);
      let parsed;
      try { parsed = new URL(url + '/api/ingest/push'); } catch {
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
            resolve(true);
          } else {
            process.stderr.write(`[gitprint] platform responded ${res.statusCode}: ${body}\n`);
            resolve(false);
          }
        });
      });
      req.on('error', (e) => {
        process.stderr.write(`[gitprint] platform POST failed: ${e.message}\n`);
        resolve(false);
      });
      req.setTimeout(15000, () => { req.destroy(); resolve(false); });
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

  // ─── Get commits (last 30 on this branch) ───
  let commitLog;
  try {
    commitLog = execSync(`git log --format="%H|||%s|||%an|||%aI"`, { encoding: 'utf8' })
      .trim().split('\n').filter(Boolean).slice(0, 30);
  } catch { process.exit(0); }
  log(`found ${commitLog.length} commits`);
  if (commitLog.length === 0) process.exit(0);

  const commits = commitLog.map(l => {
    const [sha, message, author, timestamp] = l.split('|||');
    return { sha, message: message || '', author: author || sender, timestamp: timestamp || new Date().toISOString() };
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
  if (allSessions.length === 0 && Object.keys(allFileStats).length === 0) {
    log('no AI data found in notes — skipping POST');
    process.exit(0);
  }

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
  const EXCLUDE = [/^\.claude\//, /^\.github\//, /^\.gitprint\//, /^\.cursor\//, /^\.vscode\//, /^\.idea\//];
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
    };
  });

  // ─── Build + POST payload ───
  const tools = [...new Set(allSessions.map(s => s.tool || 'claude-code').filter(Boolean))];
  const payload = { repo, branch, sender, sessions: allSessions, files, commits: commitDetails, totalCost, totalTokens, tools };

  const ok = await postToPlatform(platformUrl, platformToken, payload);
  if (!ok) {
    fs.appendFileSync(outboxFile, JSON.stringify(payload) + '\n');
    process.stderr.write('[gitprint] ingest queued (.git/gitprint-outbox.jsonl) — will retry on next commit\n');
  }

})().catch((e) => {
  process.stderr.write(`[gitprint] post-commit error: ${e.message}\n`);
});
NODEEOF

exit 0
