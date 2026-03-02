const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

describe('Augment Code hooks', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  describe('augment-post-tool.sh', () => {
    it('tracks str-replace-editor', () => {
      runHook('augment-post-tool.sh', {
        tool_name: 'str-replace-editor',
        tool_input: { file_path: 'src/app.py', old_string: 'old', new_string: 'new\nline' },
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), 'utf8'));
      assert.strictEqual(pending['src/app.py'].added, 2);
      assert.strictEqual(pending['src/app.py'].removed, 1);
    });

    it('tracks save-file', () => {
      runHook('augment-post-tool.sh', {
        tool_name: 'save-file',
        tool_input: { file_path: 'src/new.py', content: 'a\nb\nc\nd' },
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), 'utf8'));
      assert.strictEqual(pending['src/new.py'].added, 4);
      assert.strictEqual(pending['src/new.py'].removed, 0);
    });

    it('tracks create-file', () => {
      runHook('augment-post-tool.sh', {
        tool_name: 'create-file',
        tool_input: { file_path: 'src/created.py', content: 'hello\nworld' },
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), 'utf8'));
      assert.strictEqual(pending['src/created.py'].added, 2);
    });

    it('skips non-tracked tools', () => {
      runHook('augment-post-tool.sh', {
        tool_name: 'read-file',
        tool_input: { file_path: 'src/app.py' },
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      assert.ok(!fs.existsSync(path.join(gitDir, 'gitprint-augment-pending.json')));
    });

    it('processes file_changes array', () => {
      runHook('augment-post-tool.sh', {
        tool_name: 'str-replace-editor',
        tool_input: { file_path: 'src/app.py', old_string: 'a', new_string: 'b' },
        file_changes: [{ file_path: 'src/extra.py', lines_added: 10, lines_removed: 3 }],
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), 'utf8'));
      assert.ok(pending['src/extra.py']);
      assert.strictEqual(pending['src/extra.py'].added, 10);
      assert.strictEqual(pending['src/extra.py'].removed, 3);
    });

    it('handles tool_input as string (double-parse)', () => {
      runHook('augment-post-tool.sh', {
        tool_name: 'str-replace-editor',
        tool_input: JSON.stringify({ file_path: 'src/str.py', old_string: 'x', new_string: 'y\nz' }),
      }, { cwd: dir });
      const gitDir = path.join(dir, '.git');
      const pending = JSON.parse(fs.readFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), 'utf8'));
      assert.ok(pending['src/str.py']);
      assert.strictEqual(pending['src/str.py'].added, 2);
    });
  });

  describe('augment-stop.sh', () => {
    it('reads pending file and writes note', () => {
      const gitDir = path.join(dir, '.git');
      fs.writeFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), JSON.stringify({
        'src/app.py': { added: 5, removed: 2 },
      }));
      runHook('augment-stop.sh', { conversation_id: 'conv-aug-1', agent_stop_cause: 'done' }, { cwd: dir });
      const note = readGitNote(dir);
      assert.ok(note);
      assert.strictEqual(note.sessions[0].tool, 'augment');
    });

    it('uses conversation_id as session_id', () => {
      const gitDir = path.join(dir, '.git');
      fs.writeFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), JSON.stringify({
        'src/app.py': { added: 1, removed: 0 },
      }));
      runHook('augment-stop.sh', { conversation_id: 'conv-aug-2' }, { cwd: dir });
      const note = readGitNote(dir);
      assert.strictEqual(note.sessions[0].session_id, 'conv-aug-2');
    });

    it('deletes pending file after reading', () => {
      const gitDir = path.join(dir, '.git');
      const pendingPath = path.join(gitDir, 'gitprint-augment-pending.json');
      fs.writeFileSync(pendingPath, JSON.stringify({ 'src/a.py': { added: 1, removed: 0 } }));
      runHook('augment-stop.sh', { conversation_id: 'conv-aug-3' }, { cwd: dir });
      assert.ok(!fs.existsSync(pendingPath));
    });

    it('sets all tokens to 0', () => {
      const gitDir = path.join(dir, '.git');
      fs.writeFileSync(path.join(gitDir, 'gitprint-augment-pending.json'), JSON.stringify({
        'src/app.py': { added: 1, removed: 0 },
      }));
      runHook('augment-stop.sh', { conversation_id: 'conv-aug-4' }, { cwd: dir });
      const note = readGitNote(dir);
      assert.strictEqual(note.sessions[0].input_tokens, 0);
      assert.strictEqual(note.sessions[0].output_tokens, 0);
    });

    it('skips note when no file edits', () => {
      // No pending file
      const result = runHook('augment-stop.sh', { conversation_id: 'conv-aug-5' }, { cwd: dir });
      assert.strictEqual(result.exitCode, 0);
      const note = readGitNote(dir);
      assert.strictEqual(note, null);
    });
  });
});
