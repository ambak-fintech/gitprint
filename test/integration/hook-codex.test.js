const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

describe('Codex hook (codex-stop.sh)', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('stores an active transcript marker from stop input', () => {
    const transcript = path.join(dir, 'codex-session.jsonl');
    fs.writeFileSync(transcript, '{}\n');

    const result = runHook('codex-stop.sh', {
      session_id: 'codex-session-1',
      transcript_path: transcript,
      model: 'gpt-5-codex',
      cwd: dir,
    }, { cwd: dir });

    assert.strictEqual(result.exitCode, 0);
    assert.strictEqual(result.stdout.trim(), '{}');

    const active = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-codex-active.json'), 'utf8'));
    assert.strictEqual(active.session_id, 'codex-session-1');
    assert.strictEqual(active.transcript_path, transcript);
    assert.strictEqual(active.model, 'gpt-5-codex');
  });

  it('exits 0 on missing transcript', () => {
    const result = runHook('codex-stop.sh', {
      session_id: 'codex-session-2',
      transcript_path: '/missing.jsonl',
      model: 'gpt-5-codex',
      cwd: dir,
    }, { cwd: dir });

    assert.strictEqual(result.exitCode, 0);
  });
});
