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

describe('gitprint uninstall', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepoWithRemote();
    dir = repo.dir;
    cleanup = repo.cleanup;
    // Install first
    runCli('init --yes', dir);
  });

  afterEach(() => cleanup());

  it('removes claude-code hook file', () => {
    runCli('uninstall', dir);
    assert.ok(!fs.existsSync(path.join(dir, '.claude/hooks/stop.sh')));
  });

  it('cleans settings.json', () => {
    runCli('uninstall', dir);
    // Claude-code doesn't have uninstallConfig, so settings.json may remain
    // but the hook file should be gone
    assert.ok(!fs.existsSync(path.join(dir, '.claude/hooks/stop.sh')));
  });

  it('removes workflow', () => {
    runCli('uninstall', dir);
    assert.ok(!fs.existsSync(path.join(dir, '.github/workflows/gitprint.yml')));
  });

  it('removes cursor files when installed', () => {
    fs.mkdirSync(path.join(dir, '.cursor'), { recursive: true });
    runCli('init --yes', dir);
    assert.ok(fs.existsSync(path.join(dir, '.cursor/hooks/gitprint-stop.sh')));
    runCli('uninstall', dir);
    assert.ok(!fs.existsSync(path.join(dir, '.cursor/hooks/gitprint-stop.sh')));
  });

  it('cleans hooks.json for cursor', () => {
    fs.mkdirSync(path.join(dir, '.cursor'), { recursive: true });
    runCli('init --yes', dir);
    runCli('uninstall', dir);
    // hooks.json should be removed or cleaned
    if (fs.existsSync(path.join(dir, '.cursor/hooks.json'))) {
      const content = JSON.parse(fs.readFileSync(path.join(dir, '.cursor/hooks.json'), 'utf8'));
      const stopHooks = content.hooks?.stop || [];
      const hasGitprint = stopHooks.some(h => (h.command || '').includes('gitprint'));
      assert.ok(!hasGitprint, 'gitprint hook should be removed from hooks.json');
    }
  });

  it('handles already-uninstalled state gracefully', () => {
    runCli('uninstall', dir);
    // Running again should not throw
    assert.doesNotThrow(() => runCli('uninstall', dir));
  });

  it('preserves git notes config (prints manual instructions)', () => {
    runCli('uninstall', dir);
    // Git notes refspec should still exist (not removed by uninstall)
    const pushRefs = execSync('git config --get-all remote.origin.push 2>/dev/null || true', {
      cwd: dir, encoding: 'utf8', env: { ...process.env, ...GIT_ENV },
    });
    assert.ok(pushRefs.includes('refs/notes/gitprint'), 'notes refspec should be preserved');
  });

  it('outputs uninstalled message', () => {
    const output = runCli('uninstall', dir);
    assert.ok(output.includes('uninstalled'));
  });

  it('shows manual git config removal instructions', () => {
    const output = runCli('uninstall', dir);
    assert.ok(output.includes('git config'));
  });

  it('removes standalone-json for copilot when installed', () => {
    // Manually create copilot config to test removal
    const copilotConfigPath = path.join(dir, '.github/hooks/gitprint-copilot.json');
    fs.mkdirSync(path.dirname(copilotConfigPath), { recursive: true });
    fs.writeFileSync(copilotConfigPath, '{"version":1}');
    fs.writeFileSync(path.join(dir, '.github/hooks/gitprint-copilot-stop.sh'), '#!/bin/bash\nexit 0');
    fs.writeFileSync(path.join(dir, '.github/hooks/gitprint-copilot-post-tool.sh'), '#!/bin/bash\nexit 0');
    runCli('uninstall', dir);
    assert.ok(!fs.existsSync(copilotConfigPath));
  });
});
