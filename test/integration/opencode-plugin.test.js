const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, makeCommit, GIT_ENV } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const PLUGIN_PATH = path.join(__dirname, '..', '..', 'templates', 'opencode-plugin.js');

async function loadHooks(ctx) {
  delete require.cache[require.resolve(PLUGIN_PATH)];
  const plugin = require(PLUGIN_PATH);
  return {
    plugin,
    hooks: await plugin.GitprintPlugin(ctx),
  };
}

describe('OpenCode plugin (opencode-plugin.js)', () => {
  let dir, cleanup, originalCwd;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
    originalCwd = process.cwd();
    process.chdir(dir);
    Object.assign(process.env, GIT_ENV);
  });

  afterEach(() => {
    process.chdir(originalCwd);
    cleanup();
  });

  it('exports a plugin function', async () => {
    const { plugin, hooks } = await loadHooks({ directory: dir, worktree: dir });
    assert.strictEqual(typeof plugin.GitprintPlugin, 'function');
    assert.strictEqual(typeof hooks['tool.execute.after'], 'function');
    assert.strictEqual(typeof hooks.event, 'function');
  });

  it('tracks file edits into pending state on tool.execute.after', async () => {
    const { hooks } = await loadHooks({ directory: dir, worktree: dir });

    await hooks['tool.execute.after']({
      tool: 'edit',
      args: { file_path: 'src/app.js', old_string: 'old', new_string: 'new\nline' },
    });

    const pending = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-opencode-pending.json'), 'utf8'));
    assert.strictEqual(pending['src/app.js'].added, 2);
    assert.strictEqual(pending['src/app.js'].removed, 1);
    assert.ok(fs.existsSync(path.join(dir, '.git', 'gitprint-opencode-active.json')));
  });

  it('captures token usage from message.updated events', async () => {
    const { hooks } = await loadHooks({ directory: dir, worktree: dir });

    await hooks.event({
      event: {
        type: 'message.updated',
        session_id: 'oc-session-1',
        model: 'gpt-4o',
        usage: { input_tokens: 100, output_tokens: 50 },
      },
    });

    await hooks['tool.execute.after']({
      tool: 'write',
      args: { file_path: 'src/usage.js', content: 'a\nb' },
    });

    await hooks.event({ event: { type: 'session.idle' } });

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions[0].session_id, 'oc-session-1');
    assert.strictEqual(note.sessions[0].input_tokens, 100);
    assert.strictEqual(note.sessions[0].output_tokens, 50);
  });

  it('attaches pending OpenCode file delta on post-commit', async () => {
    const { hooks } = await loadHooks({ directory: dir, worktree: dir });

    await hooks['tool.execute.after']({
      tool: 'edit',
      args: { file_path: 'src/opencode.js', old_string: 'old', new_string: 'new\nline' },
    });

    makeCommit(dir, 'opencode delta commit');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.deepStrictEqual(note.sessions, []);

    const file = note.ai_files.find((entry) => entry.file === 'src/opencode.js');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-opencode-checkpoint.json'), 'utf8'));
    assert.strictEqual(checkpoint.files['src/opencode.js'].added, 2);
    assert.strictEqual(checkpoint.files['src/opencode.js'].removed, 1);
  });

  it('session.idle writes only leftover delta after post-commit and clears state', async () => {
    const { hooks } = await loadHooks({ directory: dir, worktree: dir });

    await hooks['tool.execute.after']({
      tool: 'edit',
      args: { file_path: 'src/opencode.js', old_string: 'old', new_string: 'new\nline' },
    });

    makeCommit(dir, 'opencode checkpoint commit');
    runHook('post-commit.sh', '', { cwd: dir });

    await hooks['tool.execute.after']({
      tool: 'create',
      args: { file_path: 'src/leftover.js', content: 'a\nb\nc' },
    });
    await hooks.event({
      event: {
        type: 'message.updated',
        session_id: 'oc-session-leftover',
        model: 'gpt-4o',
        usage: { input_tokens: 25, output_tokens: 10 },
      },
    });

    await hooks.event({ event: { type: 'session.idle' } });

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);
    assert.strictEqual(note.sessions[0].session_id, 'oc-session-leftover');
    assert.strictEqual(note.sessions[0].input_tokens, 25);
    assert.strictEqual(note.sessions[0].output_tokens, 10);

    const initialFile = note.ai_files.find((entry) => entry.file === 'src/opencode.js');
    assert.ok(initialFile);
    assert.strictEqual(initialFile.ai_lines_added, 2);
    assert.strictEqual(initialFile.ai_lines_removed, 1);

    const leftoverFile = note.ai_files.find((entry) => entry.file === 'src/leftover.js');
    assert.ok(leftoverFile);
    assert.strictEqual(leftoverFile.ai_lines_added, 3);
    assert.strictEqual(leftoverFile.ai_lines_removed, 0);

    assert.ok(!fs.existsSync(path.join(dir, '.git', 'gitprint-opencode-pending.json')));
    assert.ok(!fs.existsSync(path.join(dir, '.git', 'gitprint-opencode-active.json')));
    assert.ok(!fs.existsSync(path.join(dir, '.git', 'gitprint-opencode-checkpoint.json')));
  });

  it('skips session.idle when no data exists', async () => {
    const { hooks } = await loadHooks({ directory: dir, worktree: dir });

    await hooks.event({ event: { type: 'session.idle' } });

    const note = readGitNote(dir);
    assert.strictEqual(note, null);
  });
});
