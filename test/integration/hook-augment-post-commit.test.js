const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, makeCommit } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');
const { getToolPaths } = require('../helpers/state-path');

describe('Augment post-commit flow', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('attaches pending Augment file delta on post-commit', () => {
    runHook('augment-post-tool.sh', {
      tool_name: 'str-replace-editor',
      tool_input: { file_path: 'src/augment.py', old_string: 'old', new_string: 'new\nline' },
      cwd: dir,
    }, { cwd: dir });

    assert.ok(fs.existsSync(getToolPaths(dir, 'augment').activeFile));

    makeCommit(dir, 'augment delta commit');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.deepStrictEqual(note.sessions, []);

    const file = note.ai_files.find((entry) => entry.file === 'src/augment.py');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(getToolPaths(dir, 'augment').checkpointFile, 'utf8'));
    assert.strictEqual(checkpoint.files['src/augment.py'].added, 2);
    assert.strictEqual(checkpoint.files['src/augment.py'].removed, 1);
  });

  it('stop writes only the leftover delta after post-commit', () => {
    runHook('augment-post-tool.sh', {
      tool_name: 'str-replace-editor',
      tool_input: { file_path: 'src/augment.py', old_string: 'old', new_string: 'new\nline' },
      cwd: dir,
    }, { cwd: dir });

    makeCommit(dir, 'augment checkpoint commit');
    runHook('post-commit.sh', '', { cwd: dir });

    runHook('augment-post-tool.sh', {
      tool_name: 'create-file',
      tool_input: { file_path: 'src/leftover.py', content: 'a\nb\nc' },
      cwd: dir,
    }, { cwd: dir });

    const result = runHook('augment-stop.sh', { conversation_id: 'augment-session-1' }, { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);
    assert.strictEqual(note.sessions[0].session_id, 'augment-session-1');
    assert.strictEqual(note.sessions[0].input_tokens, 0);
    assert.strictEqual(note.sessions[0].output_tokens, 0);

    const initialFile = note.ai_files.find((entry) => entry.file === 'src/augment.py');
    assert.ok(initialFile);
    assert.strictEqual(initialFile.ai_lines_added, 2);
    assert.strictEqual(initialFile.ai_lines_removed, 1);

    const leftoverFile = note.ai_files.find((entry) => entry.file === 'src/leftover.py');
    assert.ok(leftoverFile);
    assert.strictEqual(leftoverFile.ai_lines_added, 3);
    assert.strictEqual(leftoverFile.ai_lines_removed, 0);

    assert.ok(!fs.existsSync(getToolPaths(dir, 'augment').pendingFile));
    assert.ok(!fs.existsSync(getToolPaths(dir, 'augment').activeFile));
    assert.ok(!fs.existsSync(getToolPaths(dir, 'augment').checkpointFile));
  });
});
