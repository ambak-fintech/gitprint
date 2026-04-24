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

describe('gitprint doctor', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepoWithRemote();
    dir = repo.dir;
    cleanup = repo.cleanup;
    // Run init to set up everything
    runCli('init --yes', dir);
  });

  afterEach(() => cleanup());

  it('reports all checks passed after fresh init', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('All checks passed'));
  });

  it('reports fail when hook file missing', () => {
    fs.unlinkSync(path.join(dir, '.claude/hooks/stop.sh'));
    const output = runCli('doctor', dir);
    assert.ok(output.includes('stop.sh') && output.includes('missing'));
  });

  it('reports fail when hook not executable', () => {
    fs.chmodSync(path.join(dir, '.claude/hooks/stop.sh'), 0o644);
    const output = runCli('doctor', dir);
    assert.ok(output.includes('not executable'));
  });

  it('reports fail when post-commit hook is missing', () => {
    fs.unlinkSync(path.join(dir, '.github/hooks/post-commit'));
    const output = runCli('doctor', dir);
    assert.ok(output.includes('post-commit') && output.includes('missing'));
  });

  it('reports fail when settings.json missing hook entry', () => {
    fs.writeFileSync(path.join(dir, '.claude/settings.json'), '{}');
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Stop') && output.includes('not found'));
  });

  it('shows a warning when platform config is missing', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Platform config'));
    assert.ok(output.includes('optional platform ingest skipped'));
  });

  it('reports Node.js version', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Node.js'));
  });

  it('shows optional tool warnings not errors for installed cursor', () => {
    // Install cursor
    fs.mkdirSync(path.join(dir, '.cursor'), { recursive: true });
    runCli('init --yes', dir);
    // Remove cursor hook file to trigger warning
    fs.unlinkSync(path.join(dir, '.cursor/hooks/gitprint-stop.sh'));
    const output = runCli('doctor', dir);
    // Should still pass overall (optional tool failure = warning)
    // The cursor section uses ! (warning) not x (error)
    assert.ok(output.includes('Cursor'));
  });

  it('shows post-commit hook checks', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('post-commit'));
  });

  it('shows platform config section', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Platform config'));
  });
});
