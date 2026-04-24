const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { createTestRepoWithRemote, GIT_ENV } = require('../helpers/git-repo');

const CLI = path.join(__dirname, '..', '..', 'bin', 'cli.js');

function runCli(cmd, cwd) {
  return execSync(`node "${CLI}" ${cmd}`, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...GIT_ENV },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

describe('CLI: gitprint doctor', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepoWithRemote();
    dir = repo.dir;
    cleanup = repo.cleanup;
    runCli('init --yes', dir);
  });

  afterEach(() => cleanup());

  it('passes all checks after fresh init', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('All checks passed'));
  });

  it('detects missing hook file', () => {
    fs.unlinkSync(path.join(dir, '.claude/hooks/stop.sh'));
    const output = runCli('doctor', dir);
    assert.ok(output.includes('missing'));
  });

  it('detects non-executable hook', () => {
    fs.chmodSync(path.join(dir, '.claude/hooks/stop.sh'), 0o644);
    const output = runCli('doctor', dir);
    assert.ok(output.includes('not executable'));
  });

  it('detects missing post-commit hook', () => {
    fs.unlinkSync(path.join(dir, '.github/hooks/post-commit'));
    const output = runCli('doctor', dir);
    assert.ok(output.includes('post-commit') && output.includes('missing'));
  });

  it('detects missing settings.json hook entry', () => {
    fs.writeFileSync(path.join(dir, '.claude/settings.json'), '{}');
    const output = runCli('doctor', dir);
    assert.ok(output.includes('not found'));
  });

  it('shows platform config warning when unset', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Platform config'));
    assert.ok(output.includes('optional platform ingest skipped'));
  });

  it('shows Node.js version', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.match(/Node\.js/));
  });
});
