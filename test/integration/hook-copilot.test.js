const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { createTestRepo, readGitNote, GIT_ENV } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

describe('Copilot hooks', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  describe('copilot-post-tool.sh', () => {
    it('tracks replace_string_in_file', () => {
      runHook('copilot-post-tool.sh', {
        toolName: 'replace_string_in_file',
        toolArgs: JSON.stringify({ path: 'src/handler.js', old_string: 'old', new_string: 'new\nline' }),
        cwd: dir,
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-copilot-pending.json'), 'utf8'));
      assert.ok(pending['src/handler.js']);
      assert.strictEqual(pending['src/handler.js'].added, 2);
      assert.strictEqual(pending['src/handler.js'].removed, 1);
    });

    it('tracks create_file', () => {
      runHook('copilot-post-tool.sh', {
        toolName: 'create_file',
        toolArgs: JSON.stringify({ path: 'src/new.js', content: 'a\nb\nc' }),
        cwd: dir,
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-copilot-pending.json'), 'utf8'));
      assert.strictEqual(pending['src/new.js'].added, 3);
      assert.strictEqual(pending['src/new.js'].removed, 0);
    });

    it('tracks multi_replace_string_in_file', () => {
      runHook('copilot-post-tool.sh', {
        toolName: 'multi_replace_string_in_file',
        toolArgs: JSON.stringify({
          path: 'src/multi.js',
          edits: [
            { old_string: 'a', new_string: 'b\nc' },
            { old_string: 'x\ny', new_string: 'z' },
          ],
        }),
        cwd: dir,
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-copilot-pending.json'), 'utf8'));
      assert.strictEqual(pending['src/multi.js'].added, 3); // 2 + 1
      assert.strictEqual(pending['src/multi.js'].removed, 3); // 1 + 2
    });

    it('skips read_file', () => {
      runHook('copilot-post-tool.sh', {
        toolName: 'read_file',
        toolArgs: JSON.stringify({ path: 'src/handler.js' }),
        cwd: dir,
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      assert.ok(!fs.existsSync(path.join(gitDir, 'gitprint-copilot-pending.json')));
    });

    it('accumulates across multiple invocations', () => {
      runHook('copilot-post-tool.sh', {
        toolName: 'replace_string_in_file',
        toolArgs: JSON.stringify({ path: 'src/app.js', old_string: 'a', new_string: 'b' }),
        cwd: dir,
      }, { cwd: dir });
      runHook('copilot-post-tool.sh', {
        toolName: 'replace_string_in_file',
        toolArgs: JSON.stringify({ path: 'src/app.js', old_string: 'c', new_string: 'd\ne' }),
        cwd: dir,
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-copilot-pending.json'), 'utf8'));
      assert.strictEqual(pending['src/app.js'].added, 3); // 1 + 2
      assert.strictEqual(pending['src/app.js'].removed, 2); // 1 + 1
    });
  });

  describe('copilot-stop.sh (with pending data)', () => {
    it('reads pending file and writes note', () => {
      // Write pending file manually
      const gitDir = path.join(dir, '.git');
      fs.writeFileSync(path.join(gitDir, 'gitprint-copilot-pending.json'), JSON.stringify({
        'src/handler.js': { added: 5, removed: 2 },
      }));

      // Set up mock session-state
      const fakeHome = path.join(os.tmpdir(), `copilot-home-${crypto.randomUUID()}`);
      const sessionDir = path.join(fakeHome, '.copilot', 'session-state', 'session-test-1');
      fs.mkdirSync(sessionDir, { recursive: true });
      fs.writeFileSync(path.join(sessionDir, 'workspace.yaml'), `workspace:\n  cwd: ${dir}`);
      fs.writeFileSync(path.join(sessionDir, 'events.jsonl'),
        '{"type":"assistant.message","model":"gpt-4o","usage":{"prompt_tokens":100,"completion_tokens":50}}\n');

      try {
        runHook('copilot-stop.sh', { cwd: dir }, { cwd: dir, env: { HOME: fakeHome } });
        const note = readGitNote(dir);
        assert.ok(note);
        assert.strictEqual(note.sessions[0].tool, 'copilot');
        assert.strictEqual(note.sessions[0].session_id, 'session-test-1');
        // Pending data should be used for file stats
        const file = note.ai_files.find(f => f.file === 'src/handler.js');
        assert.ok(file);
        assert.strictEqual(file.ai_lines_added, 5);
      } finally {
        fs.rmSync(fakeHome, { recursive: true, force: true });
      }
    });

    it('deletes pending file after reading', () => {
      const gitDir = path.join(dir, '.git');
      fs.writeFileSync(path.join(gitDir, 'gitprint-copilot-pending.json'), JSON.stringify({
        'src/app.js': { added: 1, removed: 0 },
      }));

      const fakeHome = path.join(os.tmpdir(), `copilot-home-${crypto.randomUUID()}`);
      const sessionDir = path.join(fakeHome, '.copilot', 'session-state', 'session-del');
      fs.mkdirSync(sessionDir, { recursive: true });
      fs.writeFileSync(path.join(sessionDir, 'workspace.yaml'), `workspace:\n  cwd: ${dir}`);
      fs.writeFileSync(path.join(sessionDir, 'events.jsonl'),
        '{"type":"assistant.message","model":"gpt-4o","usage":{"prompt_tokens":50,"completion_tokens":25}}\n');

      try {
        runHook('copilot-stop.sh', { cwd: dir }, { cwd: dir, env: { HOME: fakeHome } });
        assert.ok(!fs.existsSync(path.join(gitDir, 'gitprint-copilot-pending.json')));
      } finally {
        fs.rmSync(fakeHome, { recursive: true, force: true });
      }
    });

    it('exits 0 when no matching session', () => {
      const fakeHome = path.join(os.tmpdir(), `copilot-home-${crypto.randomUUID()}`);
      const sessionDir = path.join(fakeHome, '.copilot', 'session-state', 'session-other');
      fs.mkdirSync(sessionDir, { recursive: true });
      fs.writeFileSync(path.join(sessionDir, 'workspace.yaml'), 'workspace:\n  cwd: /different/path');
      fs.writeFileSync(path.join(sessionDir, 'events.jsonl'), '{}');

      try {
        const result = runHook('copilot-stop.sh', { cwd: dir }, { cwd: dir, env: { HOME: fakeHome } });
        assert.strictEqual(result.exitCode, 0);
      } finally {
        fs.rmSync(fakeHome, { recursive: true, force: true });
      }
    });

    it('parses prompt_tokens from events', () => {
      const fakeHome = path.join(os.tmpdir(), `copilot-home-${crypto.randomUUID()}`);
      const sessionDir = path.join(fakeHome, '.copilot', 'session-state', 'session-tokens');
      fs.mkdirSync(sessionDir, { recursive: true });
      fs.writeFileSync(path.join(sessionDir, 'workspace.yaml'), `workspace:\n  cwd: ${dir}`);
      fs.writeFileSync(path.join(sessionDir, 'events.jsonl'),
        '{"type":"assistant.message","model":"gpt-4o","usage":{"prompt_tokens":800,"completion_tokens":400}}\n');

      try {
        runHook('copilot-stop.sh', { cwd: dir }, { cwd: dir, env: { HOME: fakeHome } });
        const note = readGitNote(dir);
        assert.strictEqual(note.sessions[0].input_tokens, 800);
        assert.strictEqual(note.sessions[0].output_tokens, 400);
      } finally {
        fs.rmSync(fakeHome, { recursive: true, force: true });
      }
    });
  });
});
