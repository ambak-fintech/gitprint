const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');
const { getToolPaths } = require('../helpers/state-path');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Windsurf hook (windsurf-stop.sh)', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('stores an active transcript marker from transcript_path', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1', cwd: dir }, { cwd: dir });

    const active = JSON.parse(fs.readFileSync(getToolPaths(dir, 'windsurf').activeFile, 'utf8'));
    assert.strictEqual(active.transcript_path, transcript);
    assert.strictEqual(active.session_id, 'traj-1');
  });

  it('reads transcript_path from tool_info payloads too', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', {
      tool_info: { transcript_path: transcript },
      trajectory_id: 'traj-tool-info',
      cwd: dir,
    }, { cwd: dir });

    const active = JSON.parse(fs.readFileSync(getToolPaths(dir, 'windsurf').activeFile, 'utf8'));
    assert.strictEqual(active.transcript_path, transcript);
    assert.strictEqual(active.session_id, 'traj-tool-info');
  });

  it('falls back to execution_id', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, execution_id: 'exec-1', cwd: dir }, { cwd: dir });

    const active = JSON.parse(fs.readFileSync(getToolPaths(dir, 'windsurf').activeFile, 'utf8'));
    assert.strictEqual(active.session_id, 'exec-1');
  });

  it('exits 0 on missing transcript', () => {
    const result = runHook('windsurf-stop.sh', { transcript_path: '/missing.jsonl', trajectory_id: 'traj-1' }, { cwd: dir });
    assert.strictEqual(result.exitCode, 0);
  });
});
