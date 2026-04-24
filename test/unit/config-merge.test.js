const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { createTestRepoWithRemote, GIT_ENV } = require('../helpers/git-repo');

const CLI = path.join(__dirname, '..', '..', 'bin', 'cli.js');

function runInit(cwd, extraEnv = {}) {
  return execSync(`node "${CLI}" init --yes`, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...GIT_ENV, ...extraEnv },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

describe('gitprint init --yes', () => {
  let dir, remoteDir, cleanup;

  beforeEach(() => {
    const repo = createTestRepoWithRemote();
    dir = repo.dir;
    remoteDir = repo.remoteDir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('creates .claude/hooks/stop.sh', () => {
    runInit(dir);
    assert.ok(fs.existsSync(path.join(dir, '.claude/hooks/stop.sh')));
  });

  it('stop.sh is executable', () => {
    runInit(dir);
    const stat = fs.statSync(path.join(dir, '.claude/hooks/stop.sh'));
    assert.ok((stat.mode & 0o111) !== 0);
  });

  it('creates .claude/settings.json with Stop hook', () => {
    runInit(dir);
    const settings = JSON.parse(fs.readFileSync(path.join(dir, '.claude/settings.json'), 'utf8'));
    assert.ok(settings.hooks?.Stop);
    const hasHook = settings.hooks.Stop.some(h =>
      h.hooks?.some(hh => (hh.command || '').includes('stop.sh'))
    );
    assert.ok(hasHook, 'Stop hook not registered');
  });

  it('creates .claude/hooks/post-tool-use.sh', () => {
    runInit(dir);
    assert.ok(fs.existsSync(path.join(dir, '.claude/hooks/post-tool-use.sh')));
  });

  it('creates .github/hooks/post-commit', () => {
    runInit(dir);
    assert.ok(fs.existsSync(path.join(dir, '.github/hooks/post-commit')));
  });

  it('registers the PostToolUse hook in .claude/settings.json', () => {
    runInit(dir);
    const settings = JSON.parse(fs.readFileSync(path.join(dir, '.claude/settings.json'), 'utf8'));
    const hasHook = settings.hooks?.PostToolUse?.some(h =>
      h.hooks?.some(hh => (hh.command || '').includes('post-tool-use.sh'))
    );
    assert.ok(hasHook, 'PostToolUse hook not registered');
  });

  it('configures core.hooksPath', () => {
    runInit(dir);
    const hooksPath = execSync('git config core.hooksPath', {
      cwd: dir, encoding: 'utf8', env: { ...process.env, ...GIT_ENV },
    });
    assert.strictEqual(hooksPath.trim(), '.github/hooks');
  });

  it('does not duplicate hook entries on re-run', () => {
    runInit(dir);
    runInit(dir);
    const settings = JSON.parse(fs.readFileSync(path.join(dir, '.claude/settings.json'), 'utf8'));
    assert.strictEqual(settings.hooks.Stop.length, 1);
  });

  it('preserves existing settings.json keys', () => {
    fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude/settings.json'), JSON.stringify({ customKey: 'value' }));
    runInit(dir);
    const settings = JSON.parse(fs.readFileSync(path.join(dir, '.claude/settings.json'), 'utf8'));
    assert.strictEqual(settings.customKey, 'value');
    assert.ok(settings.hooks?.Stop);
  });

  it('merges into existing settings.json with other hooks', () => {
    fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude/settings.json'), JSON.stringify({
      hooks: { PreToolUse: [{ hooks: [{ type: 'command', command: 'other-tool' }] }] }
    }));
    runInit(dir);
    const settings = JSON.parse(fs.readFileSync(path.join(dir, '.claude/settings.json'), 'utf8'));
    assert.ok(settings.hooks.PreToolUse, 'PreToolUse hook should be preserved');
    assert.ok(settings.hooks.Stop, 'Stop hook should be added');
  });

  it('installs cursor hook when .cursor/ exists', () => {
    fs.mkdirSync(path.join(dir, '.cursor'), { recursive: true });
    runInit(dir);
    assert.ok(fs.existsSync(path.join(dir, '.cursor/hooks/gitprint-stop.sh')));
  });

  it('creates hooks.json for cursor', () => {
    fs.mkdirSync(path.join(dir, '.cursor'), { recursive: true });
    runInit(dir);
    const hooksJson = JSON.parse(fs.readFileSync(path.join(dir, '.cursor/hooks.json'), 'utf8'));
    assert.ok(hooksJson.hooks?.stop);
    const hasHook = hooksJson.hooks.stop.some(h => (h.command || '').includes('gitprint-stop.sh'));
    assert.ok(hasHook);
  });

  it('outputs git add paths hint', () => {
    const output = runInit(dir);
    assert.ok(output.includes('git add'));
  });

  it('exits with error when not in git repo', () => {
    const tmpDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'nogit-'));
    try {
      assert.throws(() => {
        execSync(`node "${CLI}" init --yes`, {
          cwd: tmpDir,
          encoding: 'utf8',
          env: { ...process.env, ...GIT_ENV },
          stdio: ['pipe', 'pipe', 'pipe'],
        });
      });
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
