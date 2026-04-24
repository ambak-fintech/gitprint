const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { createTestRepo, readGitNote, makeCommit } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');
const { getToolPaths } = require('../helpers/state-path');

describe('Copilot post-commit flow', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('attaches pending Copilot file delta on post-commit', () => {
    runHook('copilot-post-tool.sh', {
      toolName: 'replace_string_in_file',
      toolArgs: JSON.stringify({ path: 'src/copilot.js', old_string: 'old', new_string: 'new\nline' }),
      cwd: dir,
    }, { cwd: dir });

    assert.ok(fs.existsSync(getToolPaths(dir, 'copilot').activeFile));

    makeCommit(dir, 'copilot delta commit');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.deepStrictEqual(note.sessions, []);

    const file = note.ai_files.find((entry) => entry.file === 'src/copilot.js');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(getToolPaths(dir, 'copilot').checkpointFile, 'utf8'));
    assert.strictEqual(checkpoint.files['src/copilot.js'].added, 2);
    assert.strictEqual(checkpoint.files['src/copilot.js'].removed, 1);
  });

  it('sessionEnd writes tokens and only the leftover delta after post-commit', () => {
    runHook('copilot-post-tool.sh', {
      toolName: 'replace_string_in_file',
      toolArgs: JSON.stringify({ path: 'src/copilot.js', old_string: 'old', new_string: 'new\nline' }),
      cwd: dir,
    }, { cwd: dir });

    makeCommit(dir, 'copilot checkpoint commit');
    runHook('post-commit.sh', '', { cwd: dir });

    runHook('copilot-post-tool.sh', {
      toolName: 'create_file',
      toolArgs: JSON.stringify({ path: 'src/leftover.js', content: 'a\nb\nc' }),
      cwd: dir,
    }, { cwd: dir });

    const fakeHome = path.join(os.tmpdir(), `copilot-home-${crypto.randomUUID()}`);
    const sessionDir = path.join(fakeHome, '.copilot', 'session-state', 'copilot-session-1');
    fs.mkdirSync(sessionDir, { recursive: true });
    fs.writeFileSync(path.join(sessionDir, 'workspace.yaml'), `workspace:\n  cwd: ${dir}`);
    fs.writeFileSync(
      path.join(sessionDir, 'events.jsonl'),
      '{"type":"assistant.message","model":"gpt-4o","usage":{"prompt_tokens":100,"completion_tokens":50}}\n',
    );

    try {
      const result = runHook('copilot-stop.sh', { cwd: dir }, { cwd: dir, env: { HOME: fakeHome } });
      assert.strictEqual(result.exitCode, 0);

      const note = readGitNote(dir);
      assert.ok(note);
      assert.strictEqual(note.sessions.length, 1);
      assert.strictEqual(note.sessions[0].session_id, 'copilot-session-1');
      assert.strictEqual(note.sessions[0].input_tokens, 100);
      assert.strictEqual(note.sessions[0].output_tokens, 50);

      const initialFile = note.ai_files.find((entry) => entry.file === 'src/copilot.js');
      assert.ok(initialFile);
      assert.strictEqual(initialFile.ai_lines_added, 2);
      assert.strictEqual(initialFile.ai_lines_removed, 1);

      const leftoverFile = note.ai_files.find((entry) => entry.file === 'src/leftover.js');
      assert.ok(leftoverFile);
      assert.strictEqual(leftoverFile.ai_lines_added, 3);
      assert.strictEqual(leftoverFile.ai_lines_removed, 0);

      assert.ok(!fs.existsSync(getToolPaths(dir, 'copilot').pendingFile));
      assert.ok(!fs.existsSync(getToolPaths(dir, 'copilot').activeFile));
      assert.ok(!fs.existsSync(getToolPaths(dir, 'copilot').checkpointFile));
    } finally {
      fs.rmSync(fakeHome, { recursive: true, force: true });
    }
  });
});
