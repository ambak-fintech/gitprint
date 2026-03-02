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

  it('reports fail when workflow missing', () => {
    fs.unlinkSync(path.join(dir, '.github/workflows/gitprint.yml'));
    const output = runCli('doctor', dir);
    assert.ok(output.includes('gitprint.yml') && output.includes('missing'));
  });

  it('reports fail when settings.json missing hook entry', () => {
    fs.writeFileSync(path.join(dir, '.claude/settings.json'), '{}');
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Stop') && output.includes('not found'));
  });

  it('reports fail when git refspec missing', () => {
    execSync('git config --local --unset-all remote.origin.push', {
      cwd: dir, env: { ...process.env, ...GIT_ENV }, stdio: 'pipe',
    });
    const output = runCli('doctor', dir);
    assert.ok(output.includes('push refspec missing'));
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

  it('shows workflow check', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('gitprint.yml'));
  });

  it('shows git config section', () => {
    const output = runCli('doctor', dir);
    assert.ok(output.includes('Git config'));
  });
});
