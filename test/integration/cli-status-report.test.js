const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { createTestRepoWithRemote, writeGitNote, makeCommit, GIT_ENV } = require('../helpers/git-repo');

const CLI = path.join(__dirname, '..', '..', 'bin', 'cli.js');

function runCli(cmd, cwd) {
  return execSync(`node "${CLI}" ${cmd}`, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...GIT_ENV },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function gitExec(cmd, dir) {
  return execSync(cmd, {
    cwd: dir,
    encoding: 'utf8',
    env: { ...process.env, ...GIT_ENV },
    stdio: ['pipe', 'pipe', 'pipe'],
  }).trim();
}

describe('CLI: gitprint status + report', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepoWithRemote();
    dir = repo.dir;
    cleanup = repo.cleanup;

    // Ensure local branch is named "main" so detectBaseBranch() finds origin/main
    const branch = gitExec('git rev-parse --abbrev-ref HEAD', dir);
    if (branch !== 'main') {
      gitExec('git branch -m main', dir);
    }
    gitExec('git push -u origin main', dir);

    // Create a feature branch
    gitExec('git checkout -b feature-test', dir);
    makeCommit(dir, 'feature work');

    // Write a git note on the feature commit
    writeGitNote(dir, {
      sessions: [{
        session_id: 'stat-sess-1',
        tool: 'claude-code',
        timestamp: '2025-01-15T10:00:00.000Z',
        input_tokens: 5000,
        output_tokens: 2000,
        cache_creation_tokens: 1000,
        cache_read_tokens: 500,
        estimated_cost: 0.1234,
        turns: 5,
        models: { 'claude-sonnet-4-6': { input_tokens: 6500, output_tokens: 2000, turns: 5 } },
      }],
      ai_files: [
        { file: 'src/app.js', ai_lines_added: 20, ai_lines_removed: 5 },
        { file: 'src/utils.js', ai_lines_added: 10, ai_lines_removed: 0 },
      ],
    });
  });

  afterEach(() => {
    try { fs.unlinkSync(path.join(dir, 'gitprint-report.md')); } catch {}
    try { fs.unlinkSync(path.join(dir, 'custom-report.md')); } catch {}
    cleanup();
  });

  describe('gitprint status', () => {
    it('displays session count', () => {
      const output = runCli('status', dir);
      assert.ok(output.includes('Sessions: 1'));
    });

    it('displays token info', () => {
      const output = runCli('status', dir);
      assert.ok(output.includes('Tokens:'));
    });

    it('displays cost', () => {
      const output = runCli('status', dir);
      assert.ok(output.includes('$'));
    });

    it('displays AI-touched files', () => {
      const output = runCli('status', dir);
      assert.ok(output.includes('src/app.js'));
      assert.ok(output.includes('src/utils.js'));
    });

    it('shows tool name', () => {
      const output = runCli('status', dir);
      assert.ok(output.includes('Claude Code'));
    });
  });

  describe('gitprint report', () => {
    it('creates gitprint-report.md by default', () => {
      runCli('report', dir);
      assert.ok(fs.existsSync(path.join(dir, 'gitprint-report.md')));
    });

    it('report contains Summary section', () => {
      runCli('report', dir);
      const content = fs.readFileSync(path.join(dir, 'gitprint-report.md'), 'utf8');
      assert.ok(content.includes('## Summary'));
    });

    it('report contains Session Breakdown', () => {
      runCli('report', dir);
      const content = fs.readFileSync(path.join(dir, 'gitprint-report.md'), 'utf8');
      assert.ok(content.includes('Session Breakdown'));
    });

    it('report contains AI-Touched Files', () => {
      runCli('report', dir);
      const content = fs.readFileSync(path.join(dir, 'gitprint-report.md'), 'utf8');
      assert.ok(content.includes('AI-Touched Files'));
      assert.ok(content.includes('src/app.js'));
    });

    it('custom output file name works', () => {
      runCli('report custom-report.md', dir);
      assert.ok(fs.existsSync(path.join(dir, 'custom-report.md')));
    });

    it('report contains Gitprint attribution', () => {
      runCli('report', dir);
      const content = fs.readFileSync(path.join(dir, 'gitprint-report.md'), 'utf8');
      assert.ok(content.includes('Gitprint'));
    });
  });
});
