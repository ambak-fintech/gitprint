const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, makeCommit } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

describe('Codex post-commit flow', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('attaches Codex transcript delta on post-commit', () => {
    const transcript = path.join(dir, 'codex-session.jsonl');
    fs.writeFileSync(transcript, [
      JSON.stringify({ type: 'user_message', payload: { role: 'user' } }),
      JSON.stringify({ type: 'token_count', input_tokens: 100, output_tokens: 50, cache_read_tokens: 10, model: 'gpt-5-codex' }),
      JSON.stringify({ payload: { tool: 'apply_patch', input: { patch: '*** Begin Patch\n*** Update File: src/app.js\n-old\n+new\n+line\n*** End Patch' } } }),
    ].join('\n') + '\n');

    runHook('codex-stop.sh', {
      session_id: 'codex-session-1',
      transcript_path: transcript,
      model: 'gpt-5-codex',
      cwd: dir,
    }, { cwd: dir });

    makeCommit(dir, 'codex active delta commit');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);

    const session = note.sessions[0];
    assert.strictEqual(session.session_id, 'codex-session-1');
    assert.strictEqual(session.tool, 'codex');
    assert.strictEqual(session.input_tokens, 100);
    assert.strictEqual(session.output_tokens, 50);
    assert.strictEqual(session.cache_read_tokens, 10);
    assert.strictEqual(session.turns, 1);
    assert.strictEqual(session.api_calls, 1);

    const file = note.ai_files.find((entry) => entry.file === 'src/app.js');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-codex-checkpoint.json'), 'utf8'));
    assert.strictEqual(checkpoint.transcript_path, transcript);
    assert.strictEqual(checkpoint.session_id, 'codex-session-1');
    assert.strictEqual(checkpoint.last_line, 3);
  });

  it('only attaches new Codex transcript delta after checkpoint', () => {
    const transcript = path.join(dir, 'codex-live-session.jsonl');
    fs.writeFileSync(transcript, [
      JSON.stringify({ type: 'user_message', payload: { role: 'user' } }),
      JSON.stringify({ type: 'token_count', input_tokens: 100, output_tokens: 50, cache_read_tokens: 10, model: 'gpt-5-codex' }),
      JSON.stringify({ payload: { tool: 'apply_patch', input: { patch: '*** Begin Patch\n*** Update File: src/app.js\n-old\n+new\n+line\n*** End Patch' } } }),
    ].join('\n') + '\n');

    runHook('codex-stop.sh', {
      session_id: 'codex-session-2',
      transcript_path: transcript,
      model: 'gpt-5-codex',
      cwd: dir,
    }, { cwd: dir });

    makeCommit(dir, 'codex checkpoint commit');
    runHook('post-commit.sh', '', { cwd: dir });

    fs.appendFileSync(transcript, [
      JSON.stringify({ type: 'user_message', payload: { role: 'user' } }),
      JSON.stringify({ type: 'token_count', input_tokens: 150, output_tokens: 70, cache_read_tokens: 15, model: 'gpt-5-codex' }),
      JSON.stringify({ payload: { tool: 'apply_patch', input: { patch: '*** Begin Patch\n*** Add File: src/leftover.js\n+alpha\n+beta\n*** End Patch' } } }),
    ].join('\n') + '\n');

    runHook('codex-stop.sh', {
      session_id: 'codex-session-2',
      transcript_path: transcript,
      model: 'gpt-5-codex',
      cwd: dir,
    }, { cwd: dir });

    makeCommit(dir, 'codex second commit');
    runHook('post-commit.sh', '', { cwd: dir });

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);

    const session = note.sessions[0];
    assert.strictEqual(session.session_id, 'codex-session-2');
    assert.strictEqual(session.input_tokens, 50);
    assert.strictEqual(session.output_tokens, 20);
    assert.strictEqual(session.cache_read_tokens, 5);
    assert.strictEqual(session.turns, 1);
    assert.strictEqual(session.api_calls, 1);

    const leftover = note.ai_files.find((entry) => entry.file === 'src/leftover.js');
    assert.ok(leftover);
    assert.strictEqual(leftover.ai_lines_added, 2);
    assert.strictEqual(leftover.ai_lines_removed, 0);

    const oldFile = note.ai_files.find((entry) => entry.file === 'src/app.js');
    assert.ok(!oldFile);
  });
});
